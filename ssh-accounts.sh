#!/usr/bin/env bash
set -euo pipefail

state_dir="${V6_STATE_DIR:-/etc/ssh-xray-websocket-v6}"
store="$state_dir/ssh-users.json"
action="${1:-}"
user="${2:-}"
days="${3:-}"

die() { echo "v6 SSH accounts: $*" >&2; exit 1; }
[[ "${EUID}" -eq 0 ]] || die "run as root"
command -v jq >/dev/null 2>&1 || die "jq is required"
install -d -m 700 "$state_dir"
[[ -s "$store" ]] || printf '[]\n' > "$store"
jq -e 'type == "array"' "$store" >/dev/null || die "invalid managed SSH account store"

valid_user() { [[ "$1" =~ ^[a-z_][a-z0-9_-]{0,31}$ ]]; }
valid_days() { [[ "$1" =~ ^[1-9][0-9]*$ ]]; }
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
    printf '\n═══ SSH ACCOUNT CREATED ═══\nHost: %s\nUsername: %s\nPassword: %s\nExpiry: %s\nSSH: 22, 143 | Payload/WS: 80, 8080, 8880 | TLS: 443\nPayload: GET / HTTP/1.1[crlf]Host: %s[crlf]Connection: Upgrade[crlf]Upgrade: websocket[crlf][crlf]\n' "$domain" "$user" "$password" "$expiry" "$domain"
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
