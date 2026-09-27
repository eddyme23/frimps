#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
output="${V6_TLSMUX_OUTPUT:-/usr/local/libexec/ssh-xray-websocket-v6-tlsmux}"

[[ "${EUID}" -eq 0 ]] || { echo "Run as root." >&2; exit 1; }
command -v go >/dev/null 2>&1 || { echo "Go is required to build the TLS multiplexer." >&2; exit 1; }
install -d -m 755 "$(dirname "$output")"
CGO_ENABLED=0 go build -trimpath -ldflags='-s -w' -o "$output" "$script_dir/tlsmux/main.go"
chmod 755 "$output"
echo "Built $output"
