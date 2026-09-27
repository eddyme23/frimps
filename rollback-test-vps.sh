#!/usr/bin/env bash
set -euo pipefail

state_dir="${V6_STATE_DIR:-/etc/ssh-xray-websocket-v6}"
script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
active_file="$state_dir/ACTIVE-TEST-VPS.md"

die() { echo "v6 rollback: $*" >&2; exit 1; }
[[ "${EUID}" -eq 0 ]] || die "run as root"
[[ "${V6_CONFIRM_TEST_VPS:-}" == YES ]] || die "set V6_CONFIRM_TEST_VPS=YES; this is test-VPS rollback only"
[[ -s "$active_file" ]] || die "no v6 test activation record exists"

backup_dir="$(sed -n 's/^Proxy backup: //p' "$active_file" | head -n 1)"
[[ -d "$backup_dir" ]] || die "recorded backup directory is unavailable"

systemctl stop haproxy || true
rm -f /etc/nginx/conf.d/ssh-xray-websocket-v6-main.conf
rm -f /etc/nginx/conf.d/ssh-xray-websocket-v6-ntls.conf
rm -f /etc/nginx/conf.d/ssh-xray-websocket-v6-ssh-only.conf

if [[ -f "$backup_dir/haproxy.cfg" ]]; then
  install -m 600 "$backup_dir/haproxy.cfg" /etc/haproxy/haproxy.cfg
fi
for file in ssh-xray-websocket-v6-main.conf ssh-xray-websocket-v6-ntls.conf ssh-xray-websocket-v6-ssh-only.conf; do
  [[ -f "$backup_dir/$file" ]] && install -m 600 "$backup_dir/$file" "/etc/nginx/conf.d/$file"
done
if [[ -e "$backup_dir/nginx-default-site" ]]; then
  cp -a "$backup_dir/nginx-default-site" /etc/nginx/sites-enabled/default
fi

nginx -t && systemctl reload-or-restart nginx
if [[ -f "$backup_dir/haproxy.cfg" ]]; then
  haproxy -c -f /etc/haproxy/haproxy.cfg && systemctl start haproxy
fi
"$script_dir/stop-local-backends.sh"
mv "$active_file" "$state_dir/ROLLED-BACK-$(date -u +%Y%m%dT%H%M%SZ).md"
echo "v6 test-VPS proxy configuration was rolled back from $backup_dir"
