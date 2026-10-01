#!/usr/bin/env bash
set -euo pipefail

state_dir="${V6_STATE_DIR:-/etc/ssh-xray-websocket-v6}"
protocol="${1:-}"
legacy_file="${2:-}"
expiry="${3:-}"

die() { echo "v6 legacy import: $*" >&2; exit 1; }
[[ "${EUID}" -eq 0 ]] || die "run as root"
command -v jq >/dev/null 2>&1 || die "jq is required"
[[ "$protocol" == vless ]] || die "protocol must be vless"
[[ -f "$legacy_file" ]] || die "legacy file does not exist"
[[ "$expiry" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]] || die "expiry must be YYYY-MM-DD"

store="$state_dir/users/$protocol.json"
install -d -m 700 "$state_dir/users"
[[ -s "$store" ]] || printf '[]\n' > "$store"

# Legacy Xray files use comments, which jq cannot parse. Strip comment-only
# lines and inline hash comments before parsing the client objects.
cleaned="$(mktemp)"
trap 'rm -f "$cleaned"' EXIT
sed -E '/^[[:space:]]*(#|\/\/)/d; s/[[:space:]]+#.*$//' "$legacy_file" > "$cleaned"

imported="$(jq -c --arg expiry "$expiry" '[.inbounds[]? | select(.protocol == "vless") | .settings.clients[]? | select((.email // "") != "") | {name:.email,uuid:.id,expiresAt:$expiry}] | unique_by(.name)' "$cleaned")"

[[ "$imported" != '[]' ]] || die "no importable $protocol accounts found"
conflicts="$(jq -r --argjson incoming "$imported" '[.[] as $old | $incoming[] | select(.name == $old.name) | .name] | unique[]?' "$store")"
[[ -z "$conflicts" ]] || die "refusing to overwrite existing v6 accounts: $(tr '\n' ' ' <<<"$conflicts")"

temp="$(mktemp "$state_dir/users/.${protocol}.XXXXXX")"
jq --argjson incoming "$imported" '. + $incoming' "$store" > "$temp"
chmod 600 "$temp"
mv -f "$temp" "$store"

"$(dirname "$0")/render-backends.sh"
printf 'Imported %s %s account(s) with expiry %s.\n' "$(jq 'length' <<<"$imported")" "$protocol" "$expiry"
