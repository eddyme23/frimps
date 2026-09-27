#!/usr/bin/env bash
set -euo pipefail

state_dir="${V6_STATE_DIR:-/etc/ssh-xray-websocket-v6}"
domain="${V6_DOMAIN:-}"
cert_file="${V6_CERT_FILE:-/etc/certificates/main.crt}"
key_file="${V6_KEY_FILE:-/etc/certificates/main.key}"
die() { echo "v6 OpenVPN: $*" >&2; exit 1; }
[[ $EUID -eq 0 ]] || die 'run as root'
[[ "$domain" =~ ^[A-Za-z0-9.-]+$ ]] || die 'set V6_DOMAIN'
for command in openvpn python3 node stunnel4; do command -v "$command" >/dev/null || die "missing dependency: $command"; done
[[ -x /usr/share/easy-rsa/easyrsa || -n "$(command -v easyrsa 2>/dev/null || true)" ]] || die 'missing dependency: easy-rsa'
[[ -s "$cert_file" && -s "$key_file" ]] || die 'set V6_CERT_FILE and V6_KEY_FILE to valid TLS files'

install -d -m 700 "$state_dir" /etc/openvpn/easy-rsa /etc/openvpn/server /etc/openvpn/clients
[[ -x /etc/openvpn/easy-rsa/easyrsa ]] || cp -a /usr/share/easy-rsa/. /etc/openvpn/easy-rsa/
if [[ ! -s /etc/openvpn/easy-rsa/pki/ca.crt ]]; then
  (
    cd /etc/openvpn/easy-rsa
    [[ -d pki ]] || ./easyrsa init-pki
    EASYRSA_BATCH=1 EASYRSA_REQ_CN='frimps OpenVPN CA' ./easyrsa build-ca nopass
    EASYRSA_BATCH=1 ./easyrsa build-server-full server nopass
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
dh none
ecdh-curve prime256v1
tls-crypt /etc/openvpn/tls-crypt.key
data-ciphers AES-256-GCM:AES-128-GCM
auth-user-pass-verify /usr/local/libexec/ssh-xray-websocket-v6-openvpn-auth via-file
verify-client-cert none
username-as-common-name
keepalive 10 60
persist-key
persist-tun
EOF
sed 's/^local 127.0.0.1$/port 1194/; s/^port 11940$//' /etc/openvpn/server/frimps-tcp.conf | sed 's/proto tcp-server/proto udp/' > /etc/openvpn/server/frimps-udp.conf
chmod 600 /etc/openvpn/server/frimps-*.conf

install -d -m 755 /usr/local/lib/ssh-xray-websocket-v6
cat > /usr/local/lib/ssh-xray-websocket-v6/openvpn-tcp-gateway.js <<'EOF'
const net=require('net');
net.createServer(c=>{const u=net.connect(11940,'127.0.0.1');c.pipe(u);u.pipe(c);c.on('error',()=>u.destroy());u.on('error',()=>c.destroy())}).listen(1194,'0.0.0.0');
EOF
cat > /usr/local/lib/ssh-xray-websocket-v6/openvpn-bshield.js <<'EOF'
const http=require('http'),net=require('net');
http.createServer().on('upgrade',(r,s,h)=>{if(r.url!=='/openvpn'){s.destroy();return}const u=net.connect(11940,'127.0.0.1',()=>{s.write('HTTP/1.1 101 Switching Protocols\r\nConnection: Upgrade\r\nUpgrade: websocket\r\n\r\n');if(h.length)u.write(h);s.pipe(u);u.pipe(s)});u.on('error',()=>s.destroy())}).listen(10081,'127.0.0.1');
EOF
cat > /etc/openvpn/frimps-stunnel.conf <<EOF
foreground = yes
pid = /run/frimps-openvpn-stunnel.pid
cert = $cert_file
key = $key_file
[openvpn]
accept = 0.0.0.0:8433
connect = 127.0.0.1:1194
EOF
chmod 600 /etc/openvpn/frimps-stunnel.conf

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
cat > /etc/systemd/system/frimps-openvpn-gateway.service <<'EOF'
[Unit]
Description=frimps OpenVPN public TCP gateway
After=frimps-openvpn-tcp.service
Requires=frimps-openvpn-tcp.service
[Service]
ExecStart=/usr/bin/node /usr/local/lib/ssh-xray-websocket-v6/openvpn-tcp-gateway.js
Restart=on-failure
[Install]
WantedBy=multi-user.target
EOF
cat > /etc/systemd/system/frimps-openvpn-bshield.service <<'EOF'
[Unit]
Description=frimps OpenVPN HTTP upgrade bridge
After=frimps-openvpn-tcp.service
Requires=frimps-openvpn-tcp.service
[Service]
ExecStart=/usr/bin/node /usr/local/lib/ssh-xray-websocket-v6/openvpn-bshield.js
Restart=on-failure
[Install]
WantedBy=multi-user.target
EOF
cat > /etc/systemd/system/frimps-openvpn-stunnel.service <<'EOF'
[Unit]
Description=frimps OpenVPN TLS transport
After=frimps-openvpn-gateway.service
Requires=frimps-openvpn-gateway.service
[Service]
ExecStart=/usr/bin/stunnel4 /etc/openvpn/frimps-stunnel.conf
Restart=on-failure
[Install]
WantedBy=multi-user.target
EOF
systemctl daemon-reload
echo 'OpenVPN UDP 1194, TCP 1194, TLS 8433, and /openvpn bridge are installed but not enabled.'
