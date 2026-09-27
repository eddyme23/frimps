#!/usr/bin/env bash
set -euo pipefail

state_dir="${V6_STATE_DIR:-/etc/ssh-xray-websocket-v6}"
script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
mode="${1:---staged}"

ok=0
bad=0
pass() { printf '[OK] %s\n' "$1"; ok=$((ok + 1)); }
fail() { printf '[FAIL] %s\n' "$1"; bad=$((bad + 1)); }
check_cmd() { if "$@" >/dev/null 2>&1; then pass "$*"; else fail "$*"; fi; }
check_listener() {
  if ss -ltn "( sport = :$1 )" | tail -n +2 | grep -q .; then pass "TCP $1 is listening"; else fail "TCP $1 is listening"; fi
}

[[ "${EUID}" -eq 0 ]] || { echo 'Run as root.' >&2; exit 1; }
case "$mode" in --staged|--live) ;; *) echo 'Use --staged or --live.' >&2; exit 1 ;; esac

if "$script_dir/validate-v6.sh" >/dev/null 2>&1; then pass 'v6 generated-state validation'; else fail 'v6 generated-state validation'; fi
for file in xray-backends.json haproxy-443.cfg nginx-main-tls.conf nginx-encrypted-ntls.conf nginx-ssh-only.conf tlsmux.service payloadgate.service; do
  [[ -s "$state_dir/$file" ]] && pass "$file exists" || fail "$file exists"
done

if [[ "$mode" == '--live' ]]; then
  domain="$(jq -r '.primaryDomain' "$state_dir/routes.json")"
  for unit in ssh-xray-websocket-v6-xray ssh-xray-websocket-v6-tlsmux ssh-xray-websocket-v6-payloadgate; do
    check_cmd systemctl is-active --quiet "$unit"
  done
  for port in 443 80 8080 8880 2082 2086; do
    check_listener "$port"
  done
  check_cmd openssl s_client -connect "127.0.0.1:443" -servername "$domain" -brief
  legacy_code="$(curl -ks -o /dev/null -w '%{http_code}' --resolve "$domain:443:127.0.0.1" "https://$domain/trntls" || true)"
  [[ "$legacy_code" == '410' ]] && pass 'legacy /trntls returns 410' || fail "legacy /trntls returns $legacy_code"
  legacy_code="$(curl -ks -o /dev/null -w '%{http_code}' --resolve "$domain:443:127.0.0.1" "https://$domain/trtls" || true)"
  [[ "$legacy_code" == '410' ]] && pass 'legacy /trtls returns 410' || fail "legacy /trtls returns $legacy_code"
fi

printf '\nResult: %s passed, %s failed\n' "$ok" "$bad"
[[ "$bad" -eq 0 ]]
