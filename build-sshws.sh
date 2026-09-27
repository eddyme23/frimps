#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
output="${V6_SSHWS_OUTPUT:-/usr/local/libexec/ssh-xray-websocket-v6-sshws}"

[[ "${EUID}" -eq 0 ]] || { echo "Run as root." >&2; exit 1; }
command -v go >/dev/null 2>&1 || { echo "Go is required to build the SSH WebSocket bridge." >&2; exit 1; }
install -d -m 755 "$(dirname "$output")"
CGO_ENABLED=0 go build -trimpath -ldflags='-s -w' -o "$output" "$script_dir/sshws/main.go"
chmod 755 "$output"
echo "Built $output"
