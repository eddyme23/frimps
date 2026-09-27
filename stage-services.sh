#!/usr/bin/env bash
set -euo pipefail

state_dir="${V6_STATE_DIR:-/etc/ssh-xray-websocket-v6}"
script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
install_dir="/etc/ssh-xray-websocket-v6"
runtime_dir="/usr/local/lib/ssh-xray-websocket-v6"

die() { echo "v6 staging: $*" >&2; exit 1; }
[[ "${EUID}" -eq 0 ]] || die "run as root"
for file in xray-backends.json haproxy-443.cfg nginx-main-tls.conf nginx-encrypted-ntls.conf nginx-ssh-only.conf tlsmux.service payloadgate.service; do
  [[ -s "$state_dir/$file" ]] || die "missing $file; run the render scripts first"
done
for bin in xray haproxy nginx go; do command -v "$bin" >/dev/null 2>&1 || die "install $bin on the test VPS first"; done

"$script_dir/build-tlsmux.sh"
"$script_dir/build-payloadgate.sh"
xray run -test -config "$state_dir/xray-backends.json"
haproxy -c -f "$state_dir/haproxy-443.cfg"

install -d -m 700 "$install_dir"
install -d -m 755 "$runtime_dir" "$runtime_dir/tlsmux" "$runtime_dir/payloadgate"
install -m 755 "$script_dir"/*.sh "$runtime_dir/"
install -m 644 "$script_dir/tlsmux/main.go" "$runtime_dir/tlsmux/main.go"
install -m 644 "$script_dir/payloadgate/main.go" "$runtime_dir/payloadgate/main.go"
ln -sfn "$runtime_dir/menu-v6.sh" /usr/local/bin/ssh-xray-websocket-v6-menu
install -m 600 "$state_dir/xray-backends.json" "$install_dir/xray-backends.json"
install -m 600 "$state_dir/haproxy-443.cfg" "$install_dir/haproxy-443.cfg"
install -m 600 "$state_dir/nginx-main-tls.conf" "$install_dir/nginx-main-tls.conf"
install -m 600 "$state_dir/nginx-encrypted-ntls.conf" "$install_dir/nginx-encrypted-ntls.conf"
install -m 600 "$state_dir/nginx-ssh-only.conf" "$install_dir/nginx-ssh-only.conf"
install -m 644 "$state_dir/tlsmux.service" /etc/systemd/system/ssh-xray-websocket-v6-tlsmux.service
install -m 644 "$state_dir/payloadgate.service" /etc/systemd/system/ssh-xray-websocket-v6-payloadgate.service

cat > /etc/systemd/system/ssh-xray-websocket-v6-xray.service <<EOF
[Unit]
Description=ssh-xray-websocket v6 Xray backends
After=network.target

[Service]
ExecStart=/usr/local/bin/xray run -config $install_dir/xray-backends.json
Restart=on-failure
NoNewPrivileges=true
PrivateTmp=true

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
cat > "$state_dir/STAGED.md" <<EOF
# v6 services staged

Validated and staged on $(date -u +%FT%TZ).

Menu command: /usr/local/bin/ssh-xray-websocket-v6-menu

Nothing was enabled or restarted. Do not start HAProxy on this configuration
until an explicit migration has released public TCP 443 from the legacy stack.
EOF
chmod 600 "$state_dir/STAGED.md"
echo "v6 services staged; no listener was enabled or restarted."
