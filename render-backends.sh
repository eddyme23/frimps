#!/usr/bin/env bash
set -euo pipefail

state_dir="${V6_STATE_DIR:-/etc/ssh-xray-websocket-v6}"
routes="$state_dir/routes.json"
keys="$state_dir/vless-encryption.env"
runtime="$state_dir/runtime.env"
users_dir="$state_dir/users"
output="$state_dir/xray-backends.json"
backend_map="$state_dir/backends.json"

die() { echo "v6 backend renderer: $*" >&2; exit 1; }
[[ "${EUID}" -eq 0 ]] || die "run as root"
command -v jq >/dev/null 2>&1 || die "jq is required"
[[ -s "$routes" && -s "$keys" ]] || die "run install-v6.sh first"

# shellcheck disable=SC1090
source "$keys"
if [[ -s "$runtime" ]]; then
  # shellcheck disable=SC1090
  source "$runtime"
fi
[[ "${VLESS_NTLS_DECRYPTION:-}" == mlkem768x25519plus.* ]] || die "invalid VLESS NTLS decryption value"

install -d -m 700 "$users_dir"
for store in vless trojan; do
  [[ -s "$users_dir/$store.json" ]] || printf '[]\n' > "$users_dir/$store.json"
  jq -e 'type == "array"' "$users_dir/$store.json" >/dev/null || die "$store user store is not a JSON array"
done

vless_clients="$(jq 'map({id:.uuid,email:.name,level:0})' "$users_dir/vless.json")"
trojan_clients="$(jq 'map({password:.password,email:.name,level:0})' "$users_dir/trojan.json")"
vision_clients="$(jq 'map({id:.uuid,email:.name,level:0,flow:"xtls-rprx-vision"})' "$users_dir/vless.json")"
primary_domain="$(jq -r '.primaryDomain' "$routes")"
vision_domain="${V6_VISION_DOMAIN:-${V6_STORED_VISION_DOMAIN:-vision.$primary_domain}}"
cert_file="${V6_CERT_FILE:-${V6_STORED_CERT_FILE:-/etc/certificates/main.crt}}"
key_file="${V6_KEY_FILE:-${V6_STORED_KEY_FILE:-/etc/certificates/main.key}}"
special_inbounds="$(jq -n --arg visionDomain "$vision_domain" --arg cert "$cert_file" --arg key "$key_file" --argjson clients "$vision_clients" '[
  {tag:"vless-tls-vision",listen:"127.0.0.1",port:8444,protocol:"vless",settings:{clients:$clients,decryption:"none"},streamSettings:{network:"tcp",security:"tls",tlsSettings:{serverName:$visionDomain,alpn:["h2","http/1.1"],certificates:[{certificateFile:$cert,keyFile:$key}]}}}
]')"

if [[ -s "$state_dir/reality.env" ]]; then
  # shellcheck disable=SC1090
  source "$state_dir/reality.env"
  reality_inbound="$(jq -n --arg private "$REALITY_PRIVATE_KEY" --arg target "$REALITY_TARGET" --arg name "$REALITY_SERVER_NAME" --arg sid "$REALITY_SHORT_ID" --argjson clients "$vision_clients" '{tag:"vless-reality-vision",listen:"127.0.0.1",port:8443,protocol:"vless",settings:{clients:$clients,decryption:"none"},streamSettings:{network:"tcp",security:"reality",realitySettings:{show:false,dest:$target,xver:0,serverNames:[$name],privateKey:$private,shortIds:[$sid]}}}')"
  special_inbounds="$(jq --argjson reality "$reality_inbound" '. + [$reality]' <<<"$special_inbounds")"
fi

jq -n \
  --arg decryption "$VLESS_NTLS_DECRYPTION" \
  --argjson vless "$vless_clients" \
  --argjson trojan "$trojan_clients" \
  '{
    log: {loglevel: "warning"},
    inbounds: [
      {tag:"plain-fallback-dispatcher",listen:"0.0.0.0",port:80,protocol:"vless",settings:{clients:[],decryption:"none",fallbacks:[{path:"/vlntls",dest:"127.0.0.1:3107"},{path:"/vlhu",dest:"127.0.0.1:3114"},{path:"/vless-tcp",dest:"127.0.0.1:3117"},{path:"/openvpn",dest:"127.0.0.1:10081"},{dest:"127.0.0.1:3104"}]}},
      {tag:"plain-fallback-dispatcher-8080",listen:"0.0.0.0",port:8080,protocol:"vless",settings:{clients:[],decryption:"none",fallbacks:[{path:"/vlntls",dest:"127.0.0.1:3107"},{path:"/vlhu",dest:"127.0.0.1:3114"},{path:"/vless-tcp",dest:"127.0.0.1:3117"},{path:"/openvpn",dest:"127.0.0.1:10081"},{dest:"127.0.0.1:3104"}]}},
      {tag:"plain-fallback-dispatcher-8880",listen:"0.0.0.0",port:8880,protocol:"vless",settings:{clients:[],decryption:"none",fallbacks:[{path:"/vlntls",dest:"127.0.0.1:3107"},{path:"/vlhu",dest:"127.0.0.1:3114"},{path:"/vless-tcp",dest:"127.0.0.1:3117"},{path:"/openvpn",dest:"127.0.0.1:10081"},{dest:"127.0.0.1:3104"}]}},
      {tag:"vless-ws-tls", listen:"127.0.0.1", port:3106, protocol:"vless", settings:{clients:$vless,decryption:"none"}, streamSettings:{network:"ws",security:"none",wsSettings:{path:"/vltls"}}},
      {tag:"vless-ws-encrypted-ntls", listen:"127.0.0.1", port:3107, protocol:"vless", settings:{clients:$vless,decryption:$decryption}, streamSettings:{network:"ws",security:"none",wsSettings:{path:"/vlntls"}}},
      {tag:"trojan-ws-tls", listen:"127.0.0.1", port:3108, protocol:"trojan", settings:{clients:$trojan}, streamSettings:{network:"ws",security:"none",wsSettings:{path:"/trojan"}}},
      {tag:"vless-xhttp-tls", listen:"127.0.0.1", port:3112, protocol:"vless", settings:{clients:$vless,decryption:"none"}, streamSettings:{network:"xhttp",security:"none",xhttpSettings:{path:"/vlxhttp",mode:"auto"}}},
      {tag:"vless-httpupgrade-tls", listen:"127.0.0.1", port:3113, protocol:"vless", settings:{clients:$vless,decryption:"none"}, streamSettings:{network:"httpupgrade",security:"none",httpupgradeSettings:{path:"/vlhu"}}},
      {tag:"vless-httpupgrade-encrypted-ntls", listen:"127.0.0.1", port:3114, protocol:"vless", settings:{clients:$vless,decryption:$decryption}, streamSettings:{network:"httpupgrade",security:"none",httpupgradeSettings:{path:"/vlhu"}}},
      {tag:"vless-grpc-tls", listen:"127.0.0.1", port:3115, protocol:"vless", settings:{clients:$vless,decryption:"none"}, streamSettings:{network:"grpc",security:"none",grpcSettings:{serviceName:"vlgrpc"}}},
      {tag:"vless-tcp-http-tls", listen:"127.0.0.1", port:3116, protocol:"vless", settings:{clients:$vless,decryption:"none"}, streamSettings:{network:"tcp",security:"none",tcpSettings:{header:{type:"http",request:{path:["/vless-tcp"],headers:{Host:[""],"User-Agent":["Mozilla/5.0"]}}}}}},
      {tag:"vless-tcp-http-encrypted-ntls", listen:"127.0.0.1", port:3117, protocol:"vless", settings:{clients:$vless,decryption:$decryption}, streamSettings:{network:"tcp",security:"none",tcpSettings:{header:{type:"http",request:{path:["/vless-tcp"],headers:{Host:[""]}}}}}}
    ],
    outbounds: [{protocol:"freedom",tag:"direct"},{protocol:"blackhole",tag:"blocked"}],
    routing: {rules:[{type:"field",ip:["0.0.0.0/8","10.0.0.0/8","100.64.0.0/10","127.0.0.0/8","169.254.0.0/16","172.16.0.0/12","192.0.0.0/24","192.0.2.0/24","192.168.0.0/16","198.18.0.0/15","198.51.100.0/24","203.0.113.0/24","::1/128","fc00::/7","fe80::/10"],outboundTag:"blocked"}]}
  }' | jq --argjson special "$special_inbounds" '.inbounds += $special' > "$output"
chmod 600 "$output"

jq -n '{
  version: 1,
  publicRoutes: [
    {transport:"tls-http", path:"/", backend:"ssh-websocket"},
    {transport:"tls-http", path:"/vltls", backend:"vless-ws-tls:3106"},
    {transport:"plain-http", path:"/vlntls", backend:"vless-ws-encrypted-ntls:3107"},
    {transport:"tls-http", path:"/trojan", backend:"trojan-ws-tls:3108"},
    {transport:"tls-http2", path:"/vlxhttp", backend:"vless-xhttp-tls:3112"},
    {transport:"tls-http", path:"/vlhu", backend:"vless-httpupgrade-tls:3113"},
    {transport:"plain-http", path:"/vlhu", backend:"vless-httpupgrade-encrypted-ntls:3114"},
    {transport:"tls-http2", service:"vlgrpc", backend:"vless-grpc-tls:3115"}
  ],
  forbiddenPaths: ["/trtls", "/trntls"],
  unimplemented: ["ssh-ssl-classifier", "reality-vision", "tls-vision"]
}' > "$backend_map"
chmod 600 "$backend_map"

echo "Rendered $output and $backend_map"
