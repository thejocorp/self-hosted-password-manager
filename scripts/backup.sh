#!/usr/bin/env bash
# backup.sh: a consistent copy of everything Vaultwarden needs, while it keeps running.
#
#   scripts/backup.sh [DATA_DIR] [BACKUP_DIR]        defaults: ./data ./backups
#   KEEP_DAYS=30            how long archives are kept (default 30)
#   AGE_RECIPIENT=age1...   encrypt each archive to this age key (https://age-encryption.org)
#
# The database is copied with SQLite's online backup, which is safe while Vaultwarden writes to
# it. Attachments, Sends, config.json and the RSA keys (they sign logins) are copied as files.
# The archive is private (600). Run it daily from cron or a systemd timer, and copy the archives
# off the machine: a backup on the same disk is not a backup.
set -euo pipefail
DATA=${1:-./data}
DEST=${2:-./backups}
KEEP_DAYS=${KEEP_DAYS:-30}
[ -f "$DATA/db.sqlite3" ] || { echo "no $DATA/db.sqlite3: is DATA_DIR the folder mounted at /data?" >&2; exit 1; }
umask 077
mkdir -p "$DEST"
stamp=$(date +%Y%m%d-%H%M%S)
work=$(mktemp -d "$DEST/.work-$stamp-XXXX")
trap 'rm -rf "$work"' EXIT

# 1. the database, consistent, with a check that the copy opens
if command -v sqlite3 >/dev/null; then
	sqlite3 "$DATA/db.sqlite3" ".backup '$work/db.sqlite3'"
	[ "$(sqlite3 "$work/db.sqlite3" 'PRAGMA integrity_check;')" = ok ] || { echo "database copy failed its integrity check" >&2; exit 1; }
else
	# no sqlite3 on this host: borrow one from a throwaway container
	docker run --rm -v "$(cd "$DATA" && pwd)":/data:ro -v "$work":/out alpine:3.22 \
		sh -c 'apk add -q --no-cache sqlite >/dev/null && sqlite3 /data/db.sqlite3 ".backup /out/db.sqlite3" && [ "$(sqlite3 /out/db.sqlite3 "PRAGMA integrity_check;")" = ok ]'
fi

# 2. everything else Vaultwarden keeps (whatever of it exists)
for item in attachments sends config.json rsa_key.pem rsa_key.pub.pem rsa_key.der rsa_key.pub.der; do
	[ -e "$DATA/$item" ] && cp -a "$DATA/$item" "$work/"
done

# 3. one archive, optionally encrypted
name="vaultwarden-$stamp.tar.gz"
tar -czf "$DEST/$name" -C "$work" .
if [ -n "${AGE_RECIPIENT:-}" ]; then
	age -r "$AGE_RECIPIENT" -o "$DEST/$name.age" "$DEST/$name" && rm -f "$DEST/$name" && name="$name.age"
fi
echo "backup: $DEST/$name ($(du -h "$DEST/$name" | cut -f1))"

# 4. old archives go
find "$DEST" -maxdepth 1 -name 'vaultwarden-*.tar.gz*' -mtime +"$KEEP_DAYS" -print -delete | sed 's/^/removed: /'
