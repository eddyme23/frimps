#!/usr/bin/env bash
set -euo pipefail
state_dir="${V6_STATE_DIR:-/etc/ssh-xray-websocket-v6}"
store="$state_dir/openvpn-users.json"
clients=/etc/openvpn/clients
die() { echo "v6 OpenVPN: $*" >&2; exit 1; }
[[ $EUID -eq 0 ]] || die 'run as root'
command -v jq >/dev/null || die 'install jq'
action="${1:-}"; name="${2:-}"
valid() { [[ "$1" =~ ^[a-zA-Z0-9_-]{1,32}$ ]]; }
commit() { local tmp; tmp="$(mktemp "$state_dir/.openvpn.XXXXXX")"; printf '%s\n' "$1" > "$tmp"; chmod 600 "$tmp"; mv "$tmp" "$store"; }
[[ -f "$store" ]] || die 'run openvpn-install.sh first'
install -d -m 700 "$clients"
case "$action" in
  create)
    days="${3:-}"; valid "$name" || die 'invalid username'; [[ "$days" =~ ^[1-9][0-9]{0,3}$ ]] || die 'invalid days'
    jq -e --arg n "$name" '.[] | select(.name == $n)' "$store" >/dev/null && die 'account exists'
    read -rp 'Password: ' password
    expiry="$(date -u -d "+$days days" +%F)"; hash="$(openssl passwd -6 "$password")"
    commit "$(jq --arg n "$name" --arg h "$hash" --arg e "$expiry" '. + [{name:$n,passwordHash:$h,expiresAt:$e}]' "$store")"
    cat > "$clients/$name-udp.ovpn" <<EOF
client
dev tun
proto udp
remote ${V6_DOMAIN:?set V6_DOMAIN} 1194
nobind
remote-cert-tls server
auth-user-pass
<ca>
$(cat /etc/openvpn/easy-rsa/pki/ca.crt)
</ca>
<tls-crypt>
$(cat /etc/openvpn/tls-crypt.key)
</tls-crypt>
EOF
    sed 's/^proto udp$/proto tcp-client/; s/ 1194$/ 1194/' "$clients/$name-udp.ovpn" > "$clients/$name-tcp.ovpn"
    cp "$clients/$name-tcp.ovpn" "$clients/$name-tunnelguard.ovpn"
    chmod 600 "$clients/$name-"*.ovpn
    printf '\n═══ OPENVPN ACCOUNT CREATED ═══\nHost: %s\nUsername: %s\nPassword: %s\nExpiry: %s\nUDP/TCP: 1194 | SSL Direct/Payload: 8433 | BShield WS: 80, 8080, 8880 path /openvpn\nUniversal profile: /etc/openvpn/client-template.ovpn\n' "${V6_DOMAIN:?set V6_DOMAIN}" "$name" "$password" "$expiry"
    unset password
    echo "Per-account profiles: $clients/$name-{udp,tcp}.ovpn" ;;
  renew)
    days="${3:-}"; [[ "$days" =~ ^[1-9][0-9]{0,3}$ ]] || die 'invalid days'
    jq -e --arg n "$name" '.[] | select(.name == $n)' "$store" >/dev/null || die 'account not found'
    today="$(date -u +%F)"; current="$(jq -r --arg n "$name" '.[] | select(.name == $n) | .expiresAt' "$store")"; base="$today"; [[ "$current" > "$today" ]] && base="$current"; expiry="$(date -u -d "$base +$days days" +%F)"
    commit "$(jq --arg n "$name" --arg e "$expiry" 'map(if .name == $n then .expiresAt = $e else . end)' "$store")" ;;
  reset-password)
    valid "$name" || die 'invalid username'; jq -e --arg n "$name" '.[] | select(.name == $n)' "$store" >/dev/null || die 'account not found'
    read -r -p 'New password: ' password; [[ -n "$password" ]] || die 'empty passwords are not allowed'
    hash="$(openssl passwd -6 "$password")"; commit "$(jq --arg n "$name" --arg h "$hash" 'map(if .name == $n then .passwordHash = $h else . end)' "$store")"; printf 'OpenVPN password reset\nUsername: %s\nPassword: %s\n' "$name" "$password"; unset password hash ;;
  delete) commit "$(jq --arg n "$name" 'map(select(.name != $n))' "$store")"; rm -f "$clients/$name-"*.ovpn ;;
  list) jq -r '.[] | [.name,.expiresAt] | @tsv' "$store" | column -t -N NAME,EXPIRES ;;
  profile) cat "$clients/$name-${3:-udp}.ovpn" ;;
  generator) printf '═══ OPENVPN GENERATOR DETAILS ═══\nHost: %s\nUDP/TCP: 1194\nSSL Direct / Payload: 8433\nBShield WS: 80, 8080, 8880 path /openvpn\nAuthentication: username and password\n' "${V6_DOMAIN:-$(jq -r '.primaryDomain' "$state_dir/routes.json")}" ;;
  cleanup) today="$(date -u +%F)"; mapfile -t expired < <(jq -r --arg d "$today" '.[] | select(.expiresAt < $d) | .name' "$store"); for name in "${expired[@]}"; do [[ -n "$name" ]] && "$0" delete "$name"; done; echo "Removed ${#expired[@]} expired OpenVPN account(s)." ;;
  *) die 'usage: openvpn-accounts.sh {create NAME DAYS|renew NAME DAYS|reset-password NAME|delete NAME|list|profile NAME [udp|tcp]|generator|cleanup}' ;;
esac
