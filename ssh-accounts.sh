#!/usr/bin/env bash
set -euo pipefail

state_dir="${V6_STATE_DIR:-/etc/ssh-xray-websocket-v6}"
store="$state_dir/ssh-users.json"
action="${1:-}"
user="${2:-}"
days="${3:-}"

if [[ -t 1 && "${TERM:-dumb}" != dumb ]]; then
  RED=$'\033[1;31m'; GREEN=$'\033[1;32m'; YELLOW=$'\033[1;33m'; CYAN=$'\033[1;36m'; WHITE=$'\033[1;37m'; BOLD=$'\033[1m'; NC=$'\033[0m'
else
  RED= GREEN= YELLOW= CYAN= WHITE= BOLD= NC=
fi

die() { echo "v6 SSH accounts: $*" >&2; exit 1; }
[[ "${EUID}" -eq 0 ]] || die "run as root"
command -v jq >/dev/null 2>&1 || die "jq is required"
install -d -m 700 "$state_dir"
[[ -s "$store" ]] || printf '[]\n' > "$store"
jq -e 'type == "array"' "$store" >/dev/null || die "invalid managed SSH account store"

valid_user() { [[ "$1" =~ ^[a-z_][a-z0-9_-]{0,31}$ ]]; }
valid_days() { [[ "$1" =~ ^[1-9][0-9]*$ ]]; }
valid_ipv4() {
  local value="$1" IFS=. octet
  read -r -a octets <<<"$value"
  [[ ${#octets[@]} -eq 4 ]] || return 1
  for octet in "${octets[@]}"; do
    [[ "$octet" =~ ^[0-9]{1,3}$ ]] && ((10#$octet <= 255)) || return 1
  done
}
slowdns_public_ipv4() {
  local candidate
  candidate="$(curl -4fsS --connect-timeout 3 --max-time 5 https://api.ipify.org 2>/dev/null || true)"
  if valid_ipv4 "$candidate"; then printf '%s' "$candidate"; return; fi
  candidate="$(ip -4 route get 1.1.1.1 2>/dev/null | awk '/src/ {for (i=1;i<=NF;i++) if ($i == "src") {print $(i+1); exit}}')"
  if valid_ipv4 "$candidate"; then printf '%s' "$candidate"; return; fi
  printf 'Not detected'
}
commit() { local temp; temp="$(mktemp "$state_dir/.ssh-users.XXXXXX")"; printf '%s\n' "$1" > "$temp"; chmod 600 "$temp"; mv -f "$temp" "$store"; }
managed() { jq -e --arg name "$1" '.[] | select(.name == $name)' "$store" >/dev/null; }

case "$action" in
  list) jq -r '.[] | [.name, .expiresAt] | @tsv' "$store"; exit 0 ;;
  choose-delete)
    mapfile -t names < <(jq -r '.[].name' "$store")
    ((${#names[@]})) || die "no v6-managed SSH accounts"
    select name in "${names[@]}"; do [[ -n "${name:-}" ]] && exec "$0" delete "$name"; done
    ;;
  create|renew|delete|cleanup) ;;
  *) die "action must be create, renew, delete, list, choose-delete, or cleanup" ;;
esac

if [[ "$action" == "cleanup" ]]; then
  today="$(date -u +%F)"
  while IFS= read -r expired; do
    id "$expired" >/dev/null 2>&1 && userdel -r "$expired" || true
  done < <(jq -r --arg today "$today" '.[] | select(.expiresAt < $today) | .name' "$store")
  commit "$(jq --arg today "$today" '[.[] | select(.expiresAt >= $today)]' "$store")"
  exit 0
fi

valid_user "$user" || die "invalid username"
case "$action" in
  create)
    valid_days "$days" || die "days must be a positive integer"
    managed "$user" && die "account already managed by v6"
    id "$user" >/dev/null 2>&1 && die "a Linux user with this name already exists"
    read -r -p "Password for $user: " password
    [[ -n "$password" ]] || die "empty passwords are not allowed"
    expiry="$(date -u -d "+$days days" +%F)"
    hash="$(printf '%s' "$password" | openssl passwd -6 -stdin)"
    useradd -m -s /bin/bash "$user"
    if ! usermod -p "$hash" "$user" || ! chage -E "$expiry" "$user"; then
      userdel -r "$user" || true
      die "account creation failed and was rolled back"
    fi
    commit "$(jq --arg name "$user" --arg expiry "$expiry" '. + [{name:$name,expiresAt:$expiry}]' "$store")"
    domain="$(jq -r '.primaryDomain // empty' "$state_dir/routes.json")"
    slowdns_ns='Not configured'; [[ -r "$state_dir/service-options.env" ]] && source "$state_dir/service-options.env" && slowdns_ns="${V6_SLOWDNS_NS:-$slowdns_ns}"
    slowdns_ip="$(slowdns_public_ipv4)"
    slowdns_pubkey="$(cat /etc/slowdns/server.pub 2>/dev/null || printf '%s' '7fbd1f8aa0abfe15a7903e837f78aba39cf61d36f183bd604daa2fe4ef3b7b59')"
    printf '\n%b══════════════════════════════════════════════════════════════%b\n' "$GREEN" "$NC"
    printf '                   %bACCOUNT CREATED SUCCESSFULLY%b\n' "$BOLD" "$NC"
    printf '%b══════════════════════════════════════════════════════════════%b\n' "$GREEN" "$NC"
    printf '  %bDomain/Host%b: %b%s%b\n' "$WHITE" "$NC" "$YELLOW" "$domain" "$NC"
    printf '  %bUsername%b   : %b%s%b\n' "$WHITE" "$NC" "$YELLOW" "$user" "$NC"
    printf '  %bPassword%b   : %b%s%b\n' "$WHITE" "$NC" "$YELLOW" "$password" "$NC"
    printf '  %bExpiry%b     : %b%s%b\n' "$WHITE" "$NC" "$YELLOW" "$expiry" "$NC"
    printf '%b--------------------------------------------------------------%b\n' "$CYAN" "$NC"
    printf '  SSH Port   : 22, 143\n  Dropbear   : 80\n  SSL/TLS    : 443\n  SSL/WS     : 443\n  WebSocket  : 80, 8080, 8880, 2082, 2086\n  SlowDNS    : 53/UDP\n  UDP Custom : 1-65535\n'
    printf '%b--------------------------------------------------------------%b\n' "$CYAN" "$NC"
    printf '  %bPayload HTTP:%b\n  %bGET / HTTP/1.1[crlf]Host: %s[crlf]Connection: Upgrade[crlf]Upgrade: websocket[crlf][crlf]%b\n\n' "$BOLD" "$NC" "$YELLOW" "$domain" "$NC"
    printf '  %bPayload Enhanced:%b\n  %bGET / HTTP/1.1[crlf]Host: bug.com[crlf][crlf]PATCH / HTTP/1.1[crlf]Host: %s[crlf]Connection: Upgrade[crlf]Upgrade: websocket[crlf][crlf]%b\n' "$BOLD" "$NC" "$YELLOW" "$domain" "$NC"
    printf '%b--------------------------------------------------------------%b\n' "$CYAN" "$NC"
    printf '  %bSlowDNS Server%b : %b%s:53%b\n' "$WHITE" "$NC" "$YELLOW" "$slowdns_ip" "$NC"
    printf '  %bSlowDNS NS%b     : %b%s%b\n' "$WHITE" "$NC" "$YELLOW" "$slowdns_ns" "$NC"
    printf '  %bDNS PUB KEY%b    : %b%s%b\n' "$WHITE" "$NC" "$YELLOW" "$slowdns_pubkey" "$NC"
    printf '%b══════════════════════════════════════════════════════════════%b\n' "$GREEN" "$NC"
    unset password hash
    ;;
  renew)
    valid_days "$days" || die "days must be a positive integer"
    managed "$user" || die "account is not v6-managed"
    today="$(date -u +%F)"; current="$(jq -r --arg name "$user" '.[] | select(.name == $name) | .expiresAt' "$store")"
    base="$today"; [[ "$current" > "$today" ]] && base="$current"
    expiry="$(date -u -d "$base +$days days" +%F)"
    chage -E "$expiry" "$user"
    commit "$(jq --arg name "$user" --arg expiry "$expiry" 'map(if .name == $name then .expiresAt=$expiry else . end)' "$store")"
    ;;
  delete)
    managed "$user" || die "account is not v6-managed"
    userdel -r "$user"
    commit "$(jq --arg name "$user" '[.[] | select(.name != $name)]' "$store")"
    ;;
esac
[[ "$action" == create ]] || echo "SSH account $action completed: $user"
