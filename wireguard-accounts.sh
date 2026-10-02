#!/usr/bin/env bash
# Managed WireGuard peer lifecycle. Generated client .conf files are the
# authoritative client artifact; wireguard:// links mirror their client settings.
set -euo pipefail

state_dir="${V6_STATE_DIR:-/etc/ssh-xray-websocket-v6}"
store="$state_dir/wireguard-users.json"
client_dir="/etc/wireguard/clients"
config="/etc/wireguard/wg0.conf"
endpoint="${V6_WG_ENDPOINT:-}"

die() { echo "v6 WireGuard: $*" >&2; exit 1; }
[[ "${EUID}" -eq 0 ]] || die 'run as root'
command -v jq >/dev/null 2>&1 || die 'install jq'
command -v wg >/dev/null 2>&1 || die 'install wireguard-tools'
[[ -f "$config" ]] || die 'WireGuard is not staged; run install-remaining-services.sh first'
[[ -n "$endpoint" ]] || endpoint="$(jq -r '.primaryDomain // empty' "$state_dir/routes.json" 2>/dev/null || true)"
[[ -n "$endpoint" ]] || die 'set V6_WG_ENDPOINT or bootstrap v6 state first'

init() { [[ -f "$store" ]] || { printf '[]\n' > "$store"; chmod 600 "$store"; }; jq -e 'type == "array"' "$store" >/dev/null || die 'invalid account store'; install -d -m 700 "$client_dir"; }
valid_name() { [[ "$1" =~ ^[a-zA-Z0-9_-]{1,32}$ ]]; }
future_date() { date -u -d "+$1 days" +%F 2>/dev/null; }
commit_store() { local temp; temp="$(mktemp "$state_dir/.wireguard-users.XXXXXX")"; printf '%s\n' "$1" > "$temp"; chmod 600 "$temp"; mv -f "$temp" "$store"; }
peer_block() { printf '\n# v6-peer:%s expires:%s\n[Peer]\nPublicKey = %s\nAllowedIPs = %s/32\n' "$1" "$2" "$3" "$4"; }
rewrite_config() {
  local name="$1" pub="$2" ip="$3" expires="$4" temp
  temp="$(mktemp /etc/wireguard/wg0.conf.XXXXXX)"
  awk -v marker="# v6-peer:$name " 'BEGIN { skip=0 } $0 ~ marker { skip=1; next } skip && /^# v6-peer:/ { skip=0 } !skip { print }' "$config" > "$temp"
  peer_block "$name" "$expires" "$pub" "$ip" >> "$temp"
  chmod 600 "$temp"; mv -f "$temp" "$config"
}
remove_peer() {
  local name="$1" temp
  temp="$(mktemp /etc/wireguard/wg0.conf.XXXXXX)"
  awk -v marker="# v6-peer:$name " 'BEGIN { skip=0 } $0 ~ marker { skip=1; next } skip && /^# v6-peer:/ { skip=0 } !skip { print }' "$config" > "$temp"
  chmod 600 "$temp"; mv -f "$temp" "$config"
}
sync_live() {
  if systemctl is-active --quiet wg-quick@wg0; then
    wg syncconf wg0 <(wg-quick strip wg0) || die 'could not apply WireGuard configuration'
  fi
}
allocate_ip() {
  local used octet
  used="$(jq -r '.[].ip' "$store")"
  for octet in $(seq 2 254); do
    if ! grep -qx "10.0.0.$octet" <<<"$used"; then printf '10.0.0.%s\n' "$octet"; return; fi
  done
  return 1
}
render_client() {
  local name="$1" private="$2" address="$3"
  local server_pub; server_pub="$(cat "$state_dir/wireguard-server-public.key")"
  cat > "$client_dir/$name.conf" <<EOF
[Interface]
PrivateKey = $private
Address = $address/32
DNS = 1.1.1.1, 1.0.0.1

[Peer]
PublicKey = $server_pub
Endpoint = $endpoint:4000
AllowedIPs = 0.0.0.0/0
PersistentKeepalive = 25
EOF
  chmod 600 "$client_dir/$name.conf"
}
wireguard_link() {
  local name="$1" row private ip server_pub private_enc ip_enc public_enc
  local client_config address dns allowed keepalive mtu client_endpoint dns_enc allowed_enc
  row="$(jq -c --arg n "$name" '.[] | select(.name == $n)' "$store")"
  [[ -n "$row" ]] || die 'account not found'
  client_config="$client_dir/$name.conf"
  private="$(awk -F ' = ' '/^PrivateKey = / {print $2; exit}' "$client_config")"
  ip="$(jq -r '.ip' <<<"$row")"
  server_pub="$(awk -F ' = ' '/^PublicKey = / {print $2; exit}' "$client_config")"
  address="$(awk -F ' = ' '/^Address = / {print $2; exit}' "$client_config")"
  dns="$(awk -F ' = ' '/^DNS = / {print $2; exit}' "$client_config")"
  allowed="$(awk -F ' = ' '/^AllowedIPs = / {print $2; exit}' "$client_config")"
  keepalive="$(awk -F ' = ' '/^PersistentKeepalive = / {print $2; exit}' "$client_config")"
  mtu="$(awk -F ' = ' '/^MTU = / {print $2; exit}' "$client_config")"
  client_endpoint="$(awk -F ' = ' '/^Endpoint = / {print $2; exit}' "$client_config")"
  private_enc="$(jq -nr --arg v "$private" '$v|@uri')"
  ip_enc="$(jq -nr --arg v "${address:-$ip/32}" '$v|@uri')"
  public_enc="$(jq -nr --arg v "$server_pub" '$v|@uri')"
  dns_enc="$(jq -nr --arg v "$dns" '$v|@uri')"
  allowed_enc="$(jq -nr --arg v "${allowed:-0.0.0.0/0}" '$v|@uri')"
  printf 'wireguard://%s@%s?address=%s&mtu=%s&publickey=%s&dns=%s&allowedips=%s&keepalive=%s#Wireguard-%s\n' "$private_enc" "${client_endpoint:-$endpoint:4000}" "$ip_enc" "${mtu:-1420}" "$public_enc" "$dns_enc" "$allowed_enc" "${keepalive:-0}" "$name"
}
migrate_dns() {
  local client temp
  shopt -s nullglob
  for client in "$client_dir"/*.conf; do
    grep -qx 'DNS = 1.1.1.1' "$client" || continue
    temp="$(mktemp "${client}.XXXXXX")"
    sed 's/^DNS = 1\.1\.1\.1$/DNS = 1.1.1.1, 1.0.0.1/' "$client" > "$temp"
    chmod 600 "$temp"
    mv -f "$temp" "$client"
    printf 'Updated WireGuard DNS fallback: %s\n' "$client"
  done
}

init
action="${1:-}"
case "$action" in
  create)
    name="${2:-}"; days="${3:-}"; valid_name "$name" || die 'username must be 1-32 letters, digits, _ or -'; [[ "$days" =~ ^[1-9][0-9]{0,3}$ ]] || die 'days must be a positive integer'
    jq -e --arg n "$name" '.[] | select(.name == $n)' "$store" >/dev/null && die 'account already exists'
    expires="$(future_date "$days")" || die 'invalid validity'
    ip="$(allocate_ip)" || die 'no WireGuard client addresses remain'
    private="$(wg genkey)"; public="$(printf '%s' "$private" | wg pubkey)"
    rewrite_config "$name" "$public" "$ip" "$expires"
    data="$(jq --arg n "$name" --arg p "$public" --arg ip "$ip" --arg e "$expires" '. + [{name:$n,publicKey:$p,ip:$ip,expiresAt:$e}]' "$store")"
    commit_store "$data"; render_client "$name" "$private" "$ip"; sync_live
    echo "Created $name ($ip), expires $expires"; echo "Client config: $client_dir/$name.conf"; echo 'WireGuard Link:'; wireguard_link "$name" ;;
  renew)
    name="${2:-}"; days="${3:-}"; [[ "$days" =~ ^[1-9][0-9]{0,3}$ ]] || die 'days must be a positive integer'
    expires="$(future_date "$days")" || die 'invalid validity'
    row="$(jq -c --arg n "$name" '.[] | select(.name == $n)' "$store")"; [[ -n "$row" ]] || die 'account not found'
    public="$(jq -r '.publicKey' <<<"$row")"; ip="$(jq -r '.ip' <<<"$row")"; rewrite_config "$name" "$public" "$ip" "$expires"
    commit_store "$(jq --arg n "$name" --arg e "$expires" 'map(if .name == $n then .expiresAt = $e else . end)' "$store")"; sync_live; echo "Renewed $name through $expires" ;;
  delete)
    name="${2:-}"; row="$(jq -c --arg n "$name" '.[] | select(.name == $n)' "$store")"; [[ -n "$row" ]] || die 'account not found'
    public="$(jq -r '.publicKey' <<<"$row")"; if systemctl is-active --quiet wg-quick@wg0; then wg set wg0 peer "$public" remove; fi
    remove_peer "$name"; commit_store "$(jq --arg n "$name" 'map(select(.name != $n))' "$store")"; rm -f "$client_dir/$name.conf"; echo "Deleted $name" ;;
  list) jq -r '.[] | [.name,.ip,.expiresAt] | @tsv' "$store" | column -t -N NAME,ADDRESS,EXPIRES ;;
  config) name="${2:-}"; [[ -f "$client_dir/$name.conf" ]] || die 'account/config not found'; cat "$client_dir/$name.conf" ;;
  link) name="${2:-}"; [[ -f "$client_dir/$name.conf" ]] || die 'account/config not found'; wireguard_link "$name" ;;
  migrate-dns) migrate_dns ;;
  cleanup)
    today="$(date -u +%F)"; jq -r --arg d "$today" '.[] | select(.expiresAt < $d) | .name' "$store" | while read -r name; do [[ -n "$name" ]] && "$0" delete "$name"; done ;;
  *) die 'usage: wireguard-accounts.sh {create NAME DAYS|renew NAME DAYS|delete NAME|list|config NAME|link NAME|migrate-dns|cleanup}' ;;
esac
