#!/usr/bin/env bash
# Refresh only the interactive Frimps menu and companion scripts.  It does not
# render configs, restart units, or change listeners.
set -euo pipefail
[[ $EUID -eq 0 ]] || { echo 'run as root' >&2; exit 1; }
script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
runtime_dir=/usr/local/lib/ssh-xray-websocket-v6
install -d -m 755 "$runtime_dir"
install -m 755 "$script_dir"/*.sh "$runtime_dir/"
ln -sfn "$runtime_dir/menu-v6.sh" /usr/local/bin/ssh-xray-websocket-v6-menu
echo 'Frimps menu refreshed. No services were restarted.'
