#!/usr/bin/env bash
# check.sh: is this Vaultwarden set up safely? Read-only: it only sends GET requests.
#
#   scripts/check.sh https://vault.example.com
#
# Run it once from inside your network and once from outside (a phone on mobile data), because
# the answers should differ for a private vault.
set -uo pipefail
URL=${1:?usage: check.sh https://vault.example.com}
URL=${URL%/}
pass=0; warn=0; fail=0
ok()   { printf '  \033[32mok\033[0m    %s\n' "$*"; pass=$((pass + 1)); }
note() { printf '  \033[33mnote\033[0m  %s\n' "$*"; warn=$((warn + 1)); }
bad()  { printf '  \033[31mFAIL\033[0m  %s\n' "$*"; fail=$((fail + 1)); }
get()  { curl -s -m 15 -o /dev/null -w '%{http_code}' "$@"; }

echo "Checking $URL"
code=$(get "$URL/alive")
case "$code" in
	200) ok "HTTPS works with a certificate this machine trusts, and Vaultwarden answers" ;;
	403) ok "answers 403 here: private and closed to this network (expected from outside)"; echo; exit 0 ;;
	000) bad "no HTTPS connection (certificate not trusted, name not resolving, or nothing listening)"; exit 1 ;;
	*)   bad "/alive answered $code" ;;
esac

cfg=$(curl -s -m 15 "$URL/api/config")
ver=$(printf '%s' "$cfg" | sed -n 's/.*"server":{[^}]*"name":"\([^"]*\)".*/\1/p')
web=$(printf '%s' "$cfg" | sed -n 's/.*"version":"\([^"]*\)".*/\1/p')
if [ -n "$ver" ]; then ok "server: ${ver} (web vault ${web:-?}); keep it updated"; else note "could not read /api/config"; fi
if printf '%s' "$cfg" | grep -q '"disableUserRegistration":true'; then
	ok "nobody can sign up on their own"
else
	note "the web vault still offers sign-up: fine if SIGNUPS_ALLOWED=false and only invitations are on, a problem if sign-ups are open"
fi

plain=${URL/https:/http:}
loc=$(curl -s -m 15 -o /dev/null -w '%{http_code} %{redirect_url}' "$plain/")
case "$loc" in
	30[18]\ https:*) ok "plain HTTP sends you to HTTPS" ;;
	000*) ok "plain HTTP is not served at all" ;;
	*) note "plain HTTP answered '$loc'" ;;
esac

admin=$(get "$URL/admin")
case "$admin" in
	404) ok "admin page is off or hidden from here" ;;
	200) note "admin page reachable from here: fine on your own network, otherwise switch it off (remove ADMIN_TOKEN)" ;;
	*)   note "admin page answered $admin" ;;
esac

hdrs=$(curl -sI -m 15 "$URL/" | tr -d '\r')
for h in strict-transport-security x-content-type-options x-frame-options content-security-policy; do
	if printf '%s\n' "$hdrs" | grep -qi "^$h:"; then ok "header $h"; else note "header $h missing"; fi
done

echo
echo "$pass ok, $warn to look at, $fail failed"
[ "$fail" -eq 0 ]
