#!/usr/bin/env bash
# Fresh-server Frimps installer for Debian 12. It installs the prerequisites,
# obtains a Cloudflare DNS-01 certificate, configures every Frimps protocol,
# then enables all Frimps-managed services for boot.
set -euo pipefail

repo_url='https://github.com/eddyme23/frimps.git'
repo_dir=/root/frimps
script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
state_dir=/etc/ssh-xray-websocket-v6

die() { printf 'Frimps installer: %s\n' "$*" >&2; exit 1; }
note() { printf '\n==> %s\n' "$*"; }
valid_host() { [[ "$1" =~ ^[A-Za-z0-9]([A-Za-z0-9.-]{0,251}[A-Za-z0-9])?$ ]]; }
valid_token() { [[ "$1" =~ ^[A-Za-z0-9._-]{12,128}$ ]]; }
valid_zivpn_password() { [[ "$1" =~ ^[A-Za-z0-9._-]{1,64}$ ]]; }
random_token() {
  if command -v openssl >/dev/null 2>&1; then openssl rand -hex 16
  elif [[ -r /proc/sys/kernel/random/uuid ]]; then tr -d '-\n' </proc/sys/kernel/random/uuid
  else od -An -N16 -tx1 /dev/urandom | tr -d ' \n'
  fi
}
ask() {
  local value
  if [[ -n "$2" ]]; then read -r -e -p "$1 [$2]: " -i "$2" value
  else read -r -p "$1: " value
  fi
  printf '%s' "${value:-$2}"
}

[[ $EUID -eq 0 ]] || die 'run as root'

# The one-line raw GitHub invocation runs a copy without the companion files.
# Bootstrap the complete, reviewable repository before doing any installation.
if [[ ! -f "$script_dir/install-v6.sh" ]]; then
  command -v apt-get >/dev/null || die 'supported only on Debian 12'
  note 'Fetching the Frimps repository'
  apt-get update
  DEBIAN_FRONTEND=noninteractive apt-get install -y ca-certificates curl git
  if [[ -d "$repo_dir/.git" ]]; then
    git -C "$repo_dir" pull --ff-only origin main
  elif [[ -e "$repo_dir" ]]; then
    die "$repo_dir exists but is not a Frimps Git repository"
  else
    git clone --depth 1 "$repo_url" "$repo_dir"
  fi
  exec bash "$repo_dir/install-frimps.sh" --from-repository
fi

[[ -r /etc/os-release ]] || die 'cannot identify the operating system'
# shellcheck disable=SC1091
source /etc/os-release
[[ "${ID:-}" == debian && "${VERSION_ID:-}" == 12 ]] || die 'this installer currently supports Debian 12 only'

note 'Frimps fresh-server setup'
printf 'Cloudflare DNS validation is used so the default certificate includes a wildcard name.\n\n'
domain="$(ask 'Primary domain' '')"
valid_host "$domain" || die 'primary domain is invalid'
cert_names="$(ask 'Certificate names (comma-separated)' "$domain,*.$domain")"
email="$(ask "Let's Encrypt email" '')"
[[ "$email" =~ ^[^[:space:]@]+@[^[:space:]@]+\.[^[:space:]@]+$ ]] || die 'email is invalid'

# Intentionally not silent: the user requested the Cloudflare token be shown
# while it is typed. It is never echoed later or written to logs.
read -r -p 'Cloudflare API token (shown while typing): ' cf_token
valid_token "$cf_token" || die 'Cloudflare API token is invalid'

slowdns_ns="$(ask 'SlowDNS nameserver' "ns.$domain")"
valid_host "$slowdns_ns" || die 'SlowDNS nameserver is invalid'
shared_obfs="$(ask 'Shared Hysteria 1 / ZiVPN obfuscation' 'frimps-9d4a7f21')"
[[ "$shared_obfs" =~ ^[A-Za-z0-9._-]{1,64}$ ]] || die 'obfuscation is invalid'
read -r -s -p 'ZiVPN password (blank = securely generate): ' zivpn_password; printf '\n'
if [[ -z "$zivpn_password" ]]; then zivpn_password="$(random_token)"; fi
valid_zivpn_password "$zivpn_password" || die 'ZiVPN password must be 1-64 letters, digits, dot, underscore, or hyphen'
read -r -s -p 'Hysteria 2 Salamander password (blank = securely generate): ' hy2_password; printf '\n'
if [[ -z "$hy2_password" ]]; then hy2_password="$(random_token)"; fi
valid_token "$hy2_password" || die 'Hysteria 2 password must be 12-128 letters, digits, dot, underscore, or hyphen'
reality_target="$(ask 'REALITY target' 'www.cloudflare.com:443')"
[[ "$reality_target" =~ ^[A-Za-z0-9.-]+:[0-9]{1,5}$ ]] || die 'REALITY target must be hostname:port'
reality_sni="$(ask 'REALITY server name / SNI' 'www.cloudflare.com')"
valid_host "$reality_sni" || die 'REALITY SNI is invalid'
reality_fingerprint="$(ask 'REALITY client fingerprint' 'chrome')"
[[ "$reality_fingerprint" =~ ^(chrome|firefox|safari|edge|android|ios)$ ]] || die 'unsupported REALITY fingerprint'
vision_domain="$(ask 'TLS Vision hostname' "vision.$domain")"
valid_host "$vision_domain" || die 'TLS Vision hostname is invalid'
enable_bbr="$(ask 'Enable native kernel BBR when available (yes/no)' 'yes')"
[[ "$enable_bbr" =~ ^(yes|no)$ ]] || die 'answer yes or no for BBR'

note 'Installing Debian dependencies'
apt-get update
DEBIAN_FRONTEND=noninteractive apt-get install -y \
  ca-certificates curl wget git jq openssl unzip tar \
  iproute2 nftables net-tools procps dnsutils cron \
  nginx haproxy dropbear-bin openvpn easy-rsa stunnel4 \
  nodejs npm golang-go wireguard-tools python3 \
  certbot python3-certbot-dns-cloudflare

download_release_asset() {
  local owner="$1" repo="$2" asset="$3" destination="$4" meta url digest actual
  meta="$(mktemp)"; trap 'rm -f "$meta"' RETURN
  curl -fsSL --retry 3 "https://api.github.com/repos/$owner/$repo/releases/latest" -o "$meta"
  url="$(jq -r --arg asset "$asset" '.assets[] | select(.name == $asset) | .browser_download_url' "$meta")"
  digest="$(jq -r --arg asset "$asset" '.assets[] | select(.name == $asset) | .digest // empty' "$meta" | sed 's/^sha256://')"
  [[ "$url" == https://* && "$digest" =~ ^[a-fA-F0-9]{64}$ ]] || die "verified release asset is unavailable: $owner/$repo/$asset"
  curl -fL --retry 3 -o "$destination" "$url"
  actual="$(sha256sum "$destination" | awk '{print $1}')"
  [[ "$actual" == "$digest" ]] || die "SHA-256 verification failed for $asset"
}

install_xray() {
  command -v xray >/dev/null 2>&1 && return
  note 'Installing verified Xray core release'
  local temp; temp="$(mktemp -d)"; trap 'rm -rf "$temp"' RETURN
  download_release_asset XTLS Xray-core Xray-linux-64.zip "$temp/xray.zip"
  unzip -qq "$temp/xray.zip" -d "$temp"
  install -m 755 "$temp/xray" /usr/local/bin/xray
  xray version >/dev/null
}

install_hysteria2() {
  command -v hysteria >/dev/null 2>&1 && return
  note 'Installing verified Hysteria 2 release'
  local temp; temp="$(mktemp -d)"; trap 'rm -rf "$temp"' RETURN
  download_release_asset apernet hysteria hysteria-linux-amd64 "$temp/hysteria"
  install -m 755 "$temp/hysteria" /usr/local/bin/hysteria
  hysteria version >/dev/null
}

install_singbox() {
  command -v sing-box >/dev/null 2>&1 && return
  note 'Installing verified sing-box release'
  local temp version asset; temp="$(mktemp -d)"; trap 'rm -rf "$temp"' RETURN
  version="$(curl -fsSL --retry 3 https://api.github.com/repos/SagerNet/sing-box/releases/latest | jq -r '.tag_name')"
  [[ "$version" =~ ^v[0-9] ]] || die 'could not determine sing-box release'
  asset="sing-box_${version#v}_linux_amd64.deb"
  download_release_asset SagerNet sing-box "$asset" "$temp/sing-box.deb"
  dpkg -i "$temp/sing-box.deb" || apt-get -f install -y
  sing-box version >/dev/null
}

install_xray
install_hysteria2
install_singbox

if [[ "$enable_bbr" == yes ]]; then
  note 'Configuring BBR when the running kernel supports it'
  if sysctl net.ipv4.tcp_available_congestion_control | grep -qw bbr; then
    cat >/etc/sysctl.d/99-frimps-bbr.conf <<'EOF'
net.core.default_qdisc=fq
net.ipv4.tcp_congestion_control=bbr
EOF
    sysctl -q -p /etc/sysctl.d/99-frimps-bbr.conf
  else
    printf 'BBR is unavailable in this kernel; continuing without it.\n' >&2
  fi
fi

note "Obtaining the wildcard TLS certificate from Let's Encrypt"
systemctl stop nginx haproxy 2>/dev/null || true
install -d -m 700 /etc/letsencrypt
cf_credentials=/etc/letsencrypt/cloudflare.ini
umask 077
printf 'dns_cloudflare_api_token = %s\n' "$cf_token" > "$cf_credentials"
unset cf_token
cert_args=()
IFS=',' read -r -a names <<<"$cert_names"
for name in "${names[@]}"; do
  name="${name//[[:space:]]/}"
  if [[ "$name" != "*.$domain" ]]; then valid_host "$name" || die "invalid certificate name: $name"; fi
  cert_args+=(-d "$name")
done
[[ ${#cert_args[@]} -gt 0 ]] || die 'at least one certificate name is required'
certbot certonly --non-interactive --agree-tos --email "$email" \
  --dns-cloudflare --dns-cloudflare-credentials "$cf_credentials" \
  --dns-cloudflare-propagation-seconds 60 --cert-name "$domain" "${cert_args[@]}"
cert_file="/etc/letsencrypt/live/$domain/fullchain.pem"
key_file="/etc/letsencrypt/live/$domain/privkey.pem"
[[ -s "$cert_file" && -s "$key_file" ]] || die 'certificate issuance did not produce expected files'

export V6_DOMAIN="$domain" V6_CERT_FILE="$cert_file" V6_KEY_FILE="$key_file"
export V6_VISION_DOMAIN="$vision_domain" V6_REALITY_TARGET="$reality_target"
export V6_REALITY_SERVER_NAME="$reality_sni" V6_REALITY_FINGERPRINT="$reality_fingerprint"
export V6_HYSTERIA1_OBFS="$shared_obfs" V6_HYSTERIA2_OBFS="$hy2_password"
export V6_ZIVPN_OBFS="$shared_obfs" V6_ZIVPN_PASSWORD="$zivpn_password"

note 'Configuring Frimps core services'
bash "$script_dir/install-v6.sh"
{
  printf 'V6_SLOWDNS_NS=%q\n' "$slowdns_ns"
  printf 'V6_HYSTERIA1_OBFS=%q\n' "$shared_obfs"
  printf 'V6_HYSTERIA2_OBFS=%q\n' "$hy2_password"
  printf 'V6_ZIVPN_OBFS=%q\n' "$shared_obfs"
  printf 'V6_ZIVPN_PASSWORD=%q\n' "$zivpn_password"
} > "$state_dir/service-options.env"
chmod 600 "$state_dir/service-options.env"
bash "$script_dir/generate-reality-keys.sh"
bash "$script_dir/render-backends.sh"
bash "$script_dir/render-routing.sh"
bash "$script_dir/validate-v6.sh"
bash "$script_dir/stage-services.sh"
V6_CONFIRM_TEST_VPS=YES V6_ALLOW_ACTIVE_V6=YES bash "$script_dir/activate-test-vps.sh"

note 'Configuring OpenVPN, WireGuard, UDP services, and Hysteria'
bash "$script_dir/install-remaining-services.sh"
bash "$script_dir/openvpn-install.sh"
bash "$script_dir/hysteria1-install.sh"
bash "$script_dir/hysteria1-accounts.sh" speed 1000 1000
bash "$script_dir/hysteria2-install.sh"
bash "$script_dir/slowdns-install.sh"
bash "$script_dir/zivpn-install.sh"
bash "$script_dir/udp-custom-install.sh"

note 'Enabling every installed Frimps service for this boot and future boots'
bash "$script_dir/refresh-menu-v6.sh"
systemctl enable --now certbot.timer
bash "$script_dir/postflight-v6.sh"

required_units='ssh-xray-websocket-v6-dropbear ssh-xray-websocket-v6-sshws ssh-xray-websocket-v6-payloadgate ssh-xray-websocket-v6-tlsmux ssh-xray-websocket-v6-xray ssh-xray-websocket-v6-udp-routing ssh-xray-websocket-v6-wireguard-nat frimps-openvpn-nat frimps-openvpn-udp frimps-openvpn-tcp frimps-openvpn-gateway frimps-openvpn-stunnel frimps-openvpn-bshield hysteria1-server hysteria2-server wg-quick@wg0 frimps-slowdns zivpn frimps-badvpn frimps-udp-custom nginx haproxy'
failed_units=()
for unit in $required_units; do
  systemctl is-active --quiet "$unit" || failed_units+=("$unit")
done
[[ ${#failed_units[@]} -eq 0 ]] || die "services failed to start: ${failed_units[*]}"

printf '\nFrimps installation completed. Menu: ssh-xray-websocket-v6-menu\n'
printf 'Primary domain: %s\nSlowDNS NS: %s\n' "$domain" "$slowdns_ns"
