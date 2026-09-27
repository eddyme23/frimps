#!/usr/bin/env bash
set -euo pipefail

state_dir="${V6_STATE_DIR:-/etc/ssh-xray-websocket-v6}"
script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
backup_dir="/var/backups/ssh-xray-websocket-v6/activate-$(date -u +%Y%m%dT%H%M%SZ)"
activated=0

die() { echo "v6 activation: $*" >&2; exit 1; }
[[ "${EUID}" -eq 0 ]] || die "run as root"
[[ "${V6_CONFIRM_TEST_VPS:-}" == YES ]] || die "set V6_CONFIRM_TEST_VPS=YES; this is test-VPS activation only"
[[ -s "$state_dir/STAGED.md" ]] || die "run stage-services.sh first"
for command in nginx haproxy systemctl; do command -v "$command" >/dev/null 2>&1 || die "missing $command"; done
trap 'if [[ "$activated" -eq 0 ]]; then "$script_dir/stop-local-backends.sh" >/dev/null 2>&1 || true; fi' EXIT

"$script_dir/preflight-cutover.sh"
"$script_dir/start-local-backends.sh"

install -d -m 700 "$backup_dir"
[[ -f /etc/haproxy/haproxy.cfg ]] && cp -a /etc/haproxy/haproxy.cfg "$backup_dir/haproxy.cfg"
[[ -f /etc/nginx/conf.d/ssh-xray-websocket-v6-main.conf ]] && cp -a /etc/nginx/conf.d/ssh-xray-websocket-v6-main.conf "$backup_dir/"
[[ -f /etc/nginx/conf.d/ssh-xray-websocket-v6-ntls.conf ]] && cp -a /etc/nginx/conf.d/ssh-xray-websocket-v6-ntls.conf "$backup_dir/"
[[ -f /etc/nginx/conf.d/ssh-xray-websocket-v6-ssh-only.conf ]] && cp -a /etc/nginx/conf.d/ssh-xray-websocket-v6-ssh-only.conf "$backup_dir/"

install -m 600 "$state_dir/nginx-main-tls.conf" /etc/nginx/conf.d/ssh-xray-websocket-v6-main.conf
install -m 600 "$state_dir/nginx-encrypted-ntls.conf" /etc/nginx/conf.d/ssh-xray-websocket-v6-ntls.conf
install -m 600 "$state_dir/nginx-ssh-only.conf" /etc/nginx/conf.d/ssh-xray-websocket-v6-ssh-only.conf
nginx -t

install -m 600 "$state_dir/haproxy-443.cfg" /etc/haproxy/haproxy.cfg
haproxy -c -f /etc/haproxy/haproxy.cfg

systemctl reload-or-restart nginx
systemctl enable --now haproxy

cat > "$state_dir/ACTIVE-TEST-VPS.md" <<EOF
# v6 active on test VPS

Activated: $(date -u +%FT%TZ)
Proxy backup: $backup_dir

Run: $script_dir/protocol-health-v6.sh --live
EOF
chmod 600 "$state_dir/ACTIVE-TEST-VPS.md"
activated=1
echo "v6 test-VPS activation completed. Run protocol-health-v6.sh --live."
