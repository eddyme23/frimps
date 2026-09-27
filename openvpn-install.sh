#!/usr/bin/env bash
set -euo pipefail

state_dir="${V6_STATE_DIR:-/etc/ssh-xray-websocket-v6}"
domain="${V6_DOMAIN:-}"
die() { echo "v6 OpenVPN: $*" >&2; exit 1; }
[[ $EUID -eq 0 ]] || die 'run as root'
[[ "$domain" =~ ^[A-Za-z0-9.-]+$ ]] || die 'set V6_DOMAIN'
for command in openvpn easyrsa python3; do command -v "$command" >/dev/null || die "missing dependency: $command"; done

install -d -m 700 "$state_dir" /etc/openvpn/easy-rsa /etc/openvpn/server /etc/openvpn/clients
[[ -x /etc/openvpn/easy-rsa/easyrsa ]] || cp -a /usr/share/easy-rsa/. /etc/openvpn/easy-rsa/
if [[ ! -s /etc/openvpn/easy-rsa/pki/ca.crt ]]; then
  (
    cd /etc/openvpn/easy-rsa
    EASYRSA_BATCH=1 EASYRSA_REQ_CN='frimps OpenVPN CA' easyrsa build-ca nopass
    EASYRSA_BATCH=1 easyrsa build-server-full server nopass
    openvpn --genkey secret /etc/openvpn/tls-crypt.key
  )
fi
chmod 600 /etc/openvpn/easy-rsa/pki/private/server.key /etc/openvpn/tls-crypt.key
[[ -f "$state_dir/openvpn-users.json" ]] || printf '[]\n' > "$state_dir/openvpn-users.json"
chmod 600 "$state_dir/openvpn-users.json"

cat > /usr/local/libexec/ssh-xray-websocket-v6-openvpn-auth <<'EOF'
#!/usr/bin/env python3
import crypt, datetime, json, sys
try:
  username, password = open(sys.argv[1]).read().splitlines()[:2]
  users = json.load(open('/etc/ssh-xray-websocket-v6/openvpn-users.json'))
  user = next((u for u in users if u['name'] == username), None)
  ok = user and user['expiresAt'] >= datetime.date.today().isoformat() and crypt.crypt(password, user['passwordHash']) == user['passwordHash']
  sys.exit(0 if ok else 1)
except Exception:
  sys.exit(1)
EOF
chmod 700 /usr/local/libexec/ssh-xray-websocket-v6-openvpn-auth

cat > /etc/openvpn/server/frimps-tcp.conf <<'EOF'
local 127.0.0.1
port 11940
proto tcp-server
dev tun
topology subnet
server 10.8.0.0 255.255.255.0
ca /etc/openvpn/easy-rsa/pki/ca.crt
cert /etc/openvpn/easy-rsa/pki/issued/server.crt
key /etc/openvpn/easy-rsa/pki/private/server.key
tls-crypt /etc/openvpn/tls-crypt.key
auth-user-pass-verify /usr/local/libexec/ssh-xray-websocket-v6-openvpn-auth via-file
verify-client-cert none
username-as-common-name
keepalive 10 60
persist-key
persist-tun
EOF
sed 's/^local 127.0.0.1$/port 1194/; s/^port 11940$//' /etc/openvpn/server/frimps-tcp.conf | sed 's/proto tcp-server/proto udp/' > /etc/openvpn/server/frimps-udp.conf
chmod 600 /etc/openvpn/server/frimps-*.conf

for type in tcp udp; do
  cat > "/etc/systemd/system/frimps-openvpn-$type.service" <<EOF
[Unit]
Description=frimps OpenVPN $type
After=network-online.target
[Service]
ExecStart=/usr/sbin/openvpn --config /etc/openvpn/server/frimps-$type.conf
Restart=on-failure
[Install]
WantedBy=multi-user.target
EOF
done
systemctl daemon-reload
echo 'OpenVPN TCP backend (127.0.0.1:11940) and UDP 1194 are installed, but not enabled.'
