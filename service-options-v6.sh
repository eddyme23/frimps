#!/usr/bin/env bash
# Interactive, root-only settings for protocol link rendering.  This script
# never changes a listener or a certificate; installers consume these values.
set -euo pipefail

state_dir="${V6_STATE_DIR:-/etc/ssh-xray-websocket-v6}"
routes="$state_dir/routes.json"
options="$state_dir/service-options.env"

die() { echo "v6 service options: $*" >&2; exit 1; }
[[ $EUID -eq 0 ]] || die 'run as root'
[[ -s "$routes" ]] || die 'run install-v6.sh first'
command -v jq >/dev/null 2>&1 || die 'install jq'

current_domain="$(jq -r '.primaryDomain // empty' "$routes")"
[[ -n "$current_domain" ]] || die 'primaryDomain is missing'

V6_SLOWDNS_NS=''
V6_HYSTERIA1_OBFS='frimps-hy1'
V6_HYSTERIA2_OBFS=''
V6_ZIVPN_OBFS='frimps-zivpn'
V6_ZIVPN_PASSWORD=''
[[ -r "$options" ]] && source "$options"

valid_hostname() { [[ "$1" =~ ^[A-Za-z0-9]([A-Za-z0-9.-]{0,251}[A-Za-z0-9])?$ ]]; }
valid_token() { [[ "$1" =~ ^[A-Za-z0-9._-]{1,64}$ ]]; }
random_token() { openssl rand -hex 12; }
ask() {
  local label="$1" current="$2" answer
  read -r -e -p "$label [$current]: " -i "$current" answer
  printf '%s' "${answer:-$current}"
}

echo '═══ FRIMPS LINK AND SERVICE OPTIONS ═══'
echo
read -r -e -p "Primary domain (must remain $current_domain because the current certificate is bound to it): " -i "$current_domain" domain
domain="${domain:-$current_domain}"
valid_hostname "$domain" || die 'invalid domain'
[[ "$domain" == "$current_domain" ]] || die 'domain migration requires a matching certificate and an explicit install-v6.sh run; no change was made'

ns="$(ask 'SlowDNS nameserver (metadata until SlowDNS is installed)' "${V6_SLOWDNS_NS:-ns.$domain}")"
valid_hostname "$ns" || die 'invalid SlowDNS nameserver'
shared_obfs="$(ask 'Shared Hysteria 1 / ZiVPN obfuscation' "${V6_HYSTERIA1_OBFS:-$V6_ZIVPN_OBFS}")"
valid_token "$shared_obfs" || die 'shared obfuscation must use letters, digits, dot, underscore, or hyphen'
hy2_default="${V6_HYSTERIA2_OBFS:-$(random_token)}"
hy2_obfs="$(ask 'Hysteria 2 Salamander password' "$hy2_default")"
valid_token "$hy2_obfs" || die 'Hysteria 2 password must use letters, digits, dot, underscore, or hyphen'
read -r -s -p 'ZiVPN password (leave blank to keep/generate one): ' zivpn_password
echo
zivpn_password="${zivpn_password:-${V6_ZIVPN_PASSWORD:-$(random_token)}}"
valid_token "$zivpn_password" || die 'ZiVPN password must use letters, digits, dot, underscore, or hyphen'

install -d -m 700 "$state_dir"
{
  printf 'V6_SLOWDNS_NS=%q\n' "$ns"
  printf 'V6_HYSTERIA1_OBFS=%q\n' "$shared_obfs"
  printf 'V6_HYSTERIA2_OBFS=%q\n' "$hy2_obfs"
  printf 'V6_ZIVPN_OBFS=%q\n' "$shared_obfs"
  printf 'V6_ZIVPN_PASSWORD=%q\n' "$zivpn_password"
} > "$options"
chmod 600 "$options"

echo 'Saved link/service options. Re-run the Hysteria installer or renderer to apply changed Hysteria settings.'
