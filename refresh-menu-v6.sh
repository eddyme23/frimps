#!/usr/bin/env bash
# Refresh the interactive Frimps menu, companion scripts, and static helpers.
# It does not render or restart configurations. It does ensure installed
# Frimps services are enabled for future boots and starts only inactive ones.
set -euo pipefail
[[ $EUID -eq 0 ]] || { echo 'run as root' >&2; exit 1; }
script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
runtime_dir=/usr/local/lib/ssh-xray-websocket-v6
helper_dir=/usr/local/libexec
install -d -m 755 "$runtime_dir"
install -m 755 "$script_dir"/*.sh "$runtime_dir/"
# Some systemd units execute immutable helper copies from /usr/local/libexec.
# Keep the helpers that are direct script copies in sync during a live refresh;
# otherwise a refreshed menu can still apply obsolete routing or render logic.
install -d -m 755 "$helper_dir"
install -m 700 "$script_dir/udp-routing.sh" "$helper_dir/ssh-xray-websocket-v6-udp-routing"
install -m 700 "$script_dir/hysteria1-render.sh" "$helper_dir/ssh-xray-websocket-v6-hysteria1-render"
install -m 700 "$script_dir/hysteria2-render.sh" "$helper_dir/ssh-xray-websocket-v6-hysteria2-render"
install -m 700 "$script_dir/wireguard-accounts.sh" "$helper_dir/ssh-xray-websocket-v6-wireguard-accounts"
ln -sfn "$runtime_dir/menu-v6.sh" /usr/local/bin/ssh-xray-websocket-v6-menu
ln -sfn "$runtime_dir/menu-v6.sh" /usr/local/bin/menu
bash "$runtime_dir/apply-service-hardening.sh"
bash "$runtime_dir/install-maintenance-timer.sh"
bash "$runtime_dir/enable-frimps-services.sh"
echo 'Frimps menu refreshed and installed services are boot-persistent.'
