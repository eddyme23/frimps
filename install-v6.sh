#!/usr/bin/env bash
set -euo pipefail

state_dir="${V6_STATE_DIR:-/etc/ssh-xray-websocket-v6}"
domain="${V6_DOMAIN:-}"
script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
backup_root="/var/backups/ssh-xray-websocket-v6"

die() { echo "v6 bootstrap: $*" >&2; exit 1; }

[[ "${EUID}" -eq 0 ]] || die "run as root"
[[ -n "$domain" ]] || die "set V6_DOMAIN to the primary TLS hostname"
[[ "$domain" =~ ^[A-Za-z0-9.-]+$ ]] || die "V6_DOMAIN is not a hostname"
command -v jq >/dev/null 2>&1 || die "install jq before running the bootstrap"

install -d -m 700 "$state_dir" "$backup_root"
stamp="$(date -u +%Y%m%dT%H%M%SZ)"
backup_dir="$backup_root/$stamp"
install -d -m 700 "$backup_dir"

for source_path in /etc/nginx /etc/haproxy /usr/local/etc/xray /etc/systemd/system; do
  if [[ -e "$source_path" ]]; then
    tar -C / -czf "$backup_dir/$(basename "$source_path").tgz" "${source_path#/}" 2>/dev/null || true
  fi
done

cat > "$state_dir/routes.json" <<EOF
{
  "schema": 1,
  "primaryDomain": "$domain",
  "removedProtocols": ["vmess"],
  "trojan": {"enabled": true, "transport": "ws", "security": "tls", "path": "/trojan"},
  "legacyTrojanPaths": [],
  "vless": {
    "tls": ["ws", "tcp-http", "xhttp", "httpupgrade", "grpc"],
    "encryptedNtls": ["tcp-http", "ws", "httpupgrade"],
    "realityVision": true,
    "tlsVision": true
  },
  "ssh": {"payloadPorts": [80, 8080, 8880], "wsNtlsPorts": [80, 8080, 8880, 2082, 2086], "tlsPort": 443},
  "udpPriority": ["slowdns", "hysteria2", "openvpn", "wireguard", "zivpn", "hysteria1", "udp-custom"],
  "udpCustomRanges": ["1-52", "54-442", "444-1193", "1195-3999", "4001-5299", "5300-5999", "50001-65535"]
}
EOF
chmod 600 "$state_dir/routes.json"

# Keep the selected TLS material and Vision hostname with the staged state.
# Account changes re-render the Xray file later, so they must not silently
# fall back to placeholder certificate paths or a different Vision hostname.
umask 077
{
  printf 'V6_STORED_VISION_DOMAIN=%q\n' "${V6_VISION_DOMAIN:-vision.$domain}"
  printf 'V6_STORED_CERT_FILE=%q\n' "${V6_CERT_FILE:-/etc/certificates/main.crt}"
  printf 'V6_STORED_KEY_FILE=%q\n' "${V6_KEY_FILE:-/etc/certificates/main.key}"
  printf 'V6_STORED_REALITY_FINGERPRINT=%q\n' "${V6_REALITY_FINGERPRINT:-chrome}"
} > "$state_dir/runtime.env"
chmod 600 "$state_dir/runtime.env"

"$script_dir/generate-vless-ntls-keys.sh"

cat > "$state_dir/ROLLBACK.md" <<EOF
# v6 bootstrap rollback

Backup created: $backup_dir

The bootstrap deliberately does not stop, restart, or replace existing services.
Restore is a manual, reviewed operation: extract only the required archive from
$backup_dir after stopping the relevant replacement service.
EOF

printf 'v6 bootstrap completed. State: %s\nBackup: %s\n' "$state_dir" "$backup_dir"
