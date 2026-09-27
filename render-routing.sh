#!/usr/bin/env bash
set -euo pipefail

state_dir="${V6_STATE_DIR:-/etc/ssh-xray-websocket-v6}"
routes="$state_dir/routes.json"
runtime="$state_dir/runtime.env"
cert_file="${V6_CERT_FILE:-}"
key_file="${V6_KEY_FILE:-}"
vision_domain="${V6_VISION_DOMAIN:-}"
reality_sni="${V6_REALITY_SNI:-}"

die() { echo "v6 routing renderer: $*" >&2; exit 1; }
[[ "${EUID}" -eq 0 ]] || die "run as root"
command -v jq >/dev/null 2>&1 || die "jq is required"
[[ -s "$routes" && -s "$state_dir/backends.json" ]] || die "run install-v6.sh and render-backends.sh first"
if [[ -s "$runtime" ]]; then source "$runtime"; fi
domain="$(jq -r '.primaryDomain' "$routes")"
[[ "$domain" != "null" && -n "$domain" ]] || die "missing primary domain"
if [[ -s "$state_dir/reality.env" ]]; then
  # shellcheck disable=SC1090
  source "$state_dir/reality.env"
  reality_sni="${reality_sni:-$REALITY_SERVER_NAME}"
fi
vision_domain="${vision_domain:-${V6_STORED_VISION_DOMAIN:-vision.$domain}}"
cert_file="${cert_file:-${V6_STORED_CERT_FILE:-/etc/certificates/main.crt}}"
key_file="${key_file:-${V6_STORED_KEY_FILE:-/etc/certificates/main.key}}"

haproxy_extra=""
if [[ -n "$reality_sni" ]]; then
  haproxy_extra+=$'    use_backend xray_reality if { req.ssl_sni -i '"$reality_sni"$' }\n'
fi
if [[ -n "$vision_domain" && "$vision_domain" != "$domain" ]]; then
  haproxy_extra+=$'    use_backend xray_vision if { req.ssl_sni -i '"$vision_domain"$' }\n'
fi

cat > "$state_dir/haproxy-443.cfg" <<EOF
global
    daemon

defaults
    mode tcp
    timeout connect 5s
    timeout client 1h
    timeout server 1h

frontend public_tcp_443
    bind :443
    tcp-request inspect-delay 5s
    tcp-request content accept if { req.ssl_hello_type 1 }
$haproxy_extra    default_backend main_tls_router

frontend public_ssh_only_tcp
    bind :2082
    bind :2086
    mode tcp
    default_backend ssh_payload_gateway

backend main_tls_router
    server main_tls_router 127.0.0.1:9443

backend xray_reality
    server xray_reality 127.0.0.1:8443

backend xray_vision
    server xray_vision 127.0.0.1:8444

EOF

cat > "$state_dir/nginx-main-tls.conf" <<EOF
# Generated v6 staging configuration. Include only after validation.
server {
    listen 127.0.0.1:9080 http2;
    server_name $domain;

    location = / {
        proxy_pass http://127.0.0.1:3102;
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host \$host;
    }

    location = /vltls {
        proxy_pass http://127.0.0.1:3106;
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host \$host;
    }

    location = /trojan {
        proxy_pass http://127.0.0.1:3108;
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host \$host;
    }

    location ^~ /vlxhttp/ {
        grpc_pass grpc://127.0.0.1:3112;
        grpc_set_header Host \$host;
    }

    location = /vlhu {
        proxy_pass http://127.0.0.1:3113;
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host \$host;
    }

    location /vlgrpc {
        grpc_pass grpc://127.0.0.1:3115;
        grpc_set_header Host \$host;
    }

    location = /vless-tcp {
        proxy_pass http://127.0.0.1:3116;
        proxy_http_version 1.1;
        proxy_set_header Host \$host;
    }

    location = /trtls { return 410; }
    location = /trntls { return 410; }
}

# HTTP/1.1 is deliberately separate: WebSocket and Trojan require it, while
# XHTTP/gRPC are routed through the HTTP/2 listener above.
server {
    listen 127.0.0.1:9081;
    server_name $domain;

    location = / { proxy_pass http://127.0.0.1:3102; proxy_http_version 1.1; proxy_set_header Upgrade \$http_upgrade; proxy_set_header Connection "upgrade"; proxy_set_header Host \$host; }
    location = /vltls { proxy_pass http://127.0.0.1:3106; proxy_http_version 1.1; proxy_set_header Upgrade \$http_upgrade; proxy_set_header Connection "upgrade"; proxy_set_header Host \$host; }
    location = /trojan { proxy_pass http://127.0.0.1:3108; proxy_http_version 1.1; proxy_set_header Upgrade \$http_upgrade; proxy_set_header Connection "upgrade"; proxy_set_header Host \$host; }
    location = /vlhu { proxy_pass http://127.0.0.1:3113; proxy_http_version 1.1; proxy_set_header Upgrade \$http_upgrade; proxy_set_header Connection "upgrade"; proxy_set_header Host \$host; }
    location = /vless-tcp { proxy_pass http://127.0.0.1:3116; proxy_http_version 1.1; proxy_set_header Host \$host; }
    location = /trtls { return 410; }
    location = /trntls { return 410; }
}
EOF

cat > "$state_dir/nginx-encrypted-ntls.conf" <<'EOF'
# Private Nginx bridge for the explicit VLESS/OpenVPN HTTP paths. HAProxy owns
# public ports and sends every unrecognised raw payload to the SSH gateway.
server {
    listen 127.0.0.1:9082;
    server_name _;

    location = /vlntls {
        proxy_pass http://127.0.0.1:3107;
        proxy_http_version 1.1;
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host $host;
    }

    location = /vlhu {
        proxy_pass http://127.0.0.1:3114;
        proxy_http_version 1.1;
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host $host;
    }

    location = /vless-tcp {
        proxy_pass http://127.0.0.1:3117;
        proxy_http_version 1.1;
        proxy_set_header Host $host;
    }

    location = /openvpn {
        proxy_pass http://127.0.0.1:10081;
        proxy_http_version 1.1;
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host $host;
    }

    location = /trojan { return 410; }
    location = /trtls { return 410; }
    location = /trntls { return 410; }
}
EOF

cat > "$state_dir/nginx-ssh-only.conf" <<'EOF'
# HAProxy owns public 2082/2086 and forwards raw SSH payloads unchanged.
EOF

chmod 600 "$state_dir/haproxy-443.cfg" "$state_dir/nginx-main-tls.conf" "$state_dir/nginx-encrypted-ntls.conf" "$state_dir/nginx-ssh-only.conf"
cat > "$state_dir/tlsmux.service" <<EOF
[Unit]
Description=ssh-xray-websocket v6 TLS multiplexer
After=network.target

[Service]
ExecStart=/usr/local/libexec/ssh-xray-websocket-v6-tlsmux -listen 127.0.0.1:9443 -cert $cert_file -key $key_file -ssh-target 127.0.0.1:143 -http1-target 127.0.0.1:9081 -h2-target 127.0.0.1:9080
Restart=on-failure
NoNewPrivileges=true
PrivateTmp=true

[Install]
WantedBy=multi-user.target
EOF
cat > "$state_dir/payloadgate.service" <<EOF
[Unit]
Description=ssh-xray-websocket v6 SSH payload gateway
After=network.target

[Service]
ExecStart=/usr/local/libexec/ssh-xray-websocket-v6-payloadgate -listen 127.0.0.1:3102 -ssh-target 127.0.0.1:143 -ws-target 127.0.0.1:3103 -legacy-target 127.0.0.1:3104
Restart=on-failure
NoNewPrivileges=true
PrivateTmp=true

[Install]
WantedBy=multi-user.target
EOF
chmod 600 "$state_dir/tlsmux.service" "$state_dir/payloadgate.service"
printf 'Rendered %s/haproxy-443.cfg and %s/nginx-main-tls.conf\n' "$state_dir" "$state_dir"
