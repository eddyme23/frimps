#!/usr/bin/env bash
# Stages the non-Xray protocol services. It never claims a service works until
# its binary, certificate, listener and client test have been verified.
set -euo pipefail

state_dir="${V6_STATE_DIR:-/etc/ssh-xray-websocket-v6}"
script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
domain="${V6_DOMAIN:-}"
cert_file="${V6_CERT_FILE:-/etc/certificates/main.crt}"
key_file="${V6_KEY_FILE:-/etc/certificates/main.key}"

die() { echo "v6 remaining services: $*" >&2; exit 1; }
[[ "${EUID}" -eq 0 ]] || die 'run as root'
[[ "$domain" =~ ^[A-Za-z0-9.-]+$ ]] || die 'set V6_DOMAIN to the primary hostname'
command -v systemctl >/dev/null 2>&1 || die 'systemd is required'
install -d -m 700 "$state_dir" /etc/ssh-xray-websocket-v6

cat > "$state_dir/remaining-services.env" <<EOF
V6_DOMAIN=$domain
V6_CERT_FILE=$cert_file
V6_KEY_FILE=$key_file
OPENVPN_TCP_PORT=1194
OPENVPN_UDP_PORT=1194
OPENVPN_TCP_BACKEND=127.0.0.1:11940
OPENVPN_SSL_PORT=8433
WIREGUARD_PORT=4000
HYSTERIA1_BACKEND_PORT=36712
HYSTERIA2_PORT=443
ZIVPN_BACKEND_PORT=5667
UDP_CUSTOM_BACKEND_PORT=36717
SLOWDNS_PORTS=53,5300
EOF
chmod 600 "$state_dir/remaining-services.env"

# The routing service is intentionally installed before consumers. All direct
# ports RETURN from its chain; range services are routed only after exceptions.
install -m 700 "$script_dir/udp-routing.sh" /usr/local/libexec/ssh-xray-websocket-v6-udp-routing
cat > /etc/systemd/system/ssh-xray-websocket-v6-udp-routing.service <<'EOF'
[Unit]
Description=ssh-xray-websocket v6 ordered UDP ingress policy
After=network-online.target
Wants=network-online.target
Before=wg-quick@wg0.service openvpn-server@udp.service hysteria2-server.service

[Service]
Type=oneshot
ExecStart=/usr/local/libexec/ssh-xray-websocket-v6-udp-routing apply
ExecStop=/usr/local/libexec/ssh-xray-websocket-v6-udp-routing remove
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF

# OpenVPN has native TCP/UDP 1194 and TLS transport on 8433. Configuration is
# staged only: PKI/user management is intentionally not fabricated here.
install -d -m 700 /etc/openvpn/server
cat > /etc/openvpn/server/tcp.conf.v6 <<'EOF'
local 127.0.0.1
port 11940
proto tcp-server
dev tun
topology subnet
server 10.8.0.0 255.255.255.0
persist-key
persist-tun
keepalive 10 60
EOF
cat > /etc/openvpn/server/udp.conf.v6 <<'EOF'
port 1194
proto udp
dev tun
topology subnet
server 10.9.0.0 255.255.255.0
persist-key
persist-tun
keepalive 10 60
EOF

# WireGuard is fully local-key based; do not overwrite an unmanaged wg0.
if [[ ! -e /etc/wireguard/wg0.conf ]]; then
  command -v wg >/dev/null 2>&1 || die 'install wireguard-tools before staging WireGuard'
  umask 077
  server_key="$(wg genkey)"
  server_pub="$(printf '%s' "$server_key" | wg pubkey)"
  cat > /etc/wireguard/wg0.conf <<EOF
# ssh-xray-websocket-v6 managed WireGuard configuration
[Interface]
Address = 10.0.0.1/24
ListenPort = 4000
PrivateKey = $server_key
SaveConfig = false
EOF
  printf '%s\n' "$server_pub" > "$state_dir/wireguard-server-public.key"
  chmod 600 /etc/wireguard/wg0.conf "$state_dir/wireguard-server-public.key"
fi

# Hysteria/ZiVPN/SlowDNS/UDP-Custom executables and their account formats vary
# by upstream release. Preserve explicit, validated placeholders instead of
# silently downloading unverified binaries or starting unauthenticated daemons.
cat > "$state_dir/REMAINING_SERVICES.md" <<EOF
# Remaining service staging

Installed: ordered UDP routing systemd unit; OpenVPN baseline configs; managed
WireGuard base configuration (only when no existing wg0 exists).

Before enabling any daemon, provide a reviewed executable and a service-specific
authenticated configuration. Required public routes are: Hysteria 1 UDP
20000-50000 -> 36712; Hysteria 2 UDP 443; ZiVPN UDP 6000-19999 -> 5667;
UDP Custom complementary ranges -> 36717; SlowDNS UDP 53 and optionally 5300.
EOF
chmod 600 "$state_dir/REMAINING_SERVICES.md"

systemctl daemon-reload
echo 'Remaining-service foundations staged. No service was enabled or started.'
echo 'Review PKI/auth configuration before enabling OpenVPN or any UDP daemon.'
