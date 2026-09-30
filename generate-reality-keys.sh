#!/usr/bin/env bash
set -euo pipefail

state_dir="${V6_STATE_DIR:-/etc/ssh-xray-websocket-v6}"
key_file="$state_dir/reality.env"
target="${V6_REALITY_TARGET:-}"
server_name="${V6_REALITY_SERVER_NAME:-}"
fingerprint="${V6_REALITY_FINGERPRINT:-chrome}"

die() { echo "v6 REALITY: $*" >&2; exit 1; }
[[ "${EUID}" -eq 0 ]] || die "run as root"
command -v xray >/dev/null 2>&1 || die "xray is required"
command -v openssl >/dev/null 2>&1 || die "openssl is required"
[[ -n "$target" && -n "$server_name" ]] || die "set V6_REALITY_TARGET and V6_REALITY_SERVER_NAME"
[[ "$fingerprint" =~ ^(chrome|firefox|safari|edge|android|ios)$ ]] || die "unsupported REALITY fingerprint"
install -d -m 700 "$state_dir"

if [[ -s "$key_file" ]]; then
  # shellcheck disable=SC1090
  source "$key_file"
  [[ -n "${REALITY_PRIVATE_KEY:-}" && -n "${REALITY_PUBLIC_KEY:-}" && -n "${REALITY_SHORT_ID:-}" ]] || die "existing REALITY state is invalid"
  exit 0
fi

pair="$(xray x25519)"
# Xray changed these labels from "Private key"/"Public key" to
# "PrivateKey"/"Password (PublicKey)".  The final whitespace-delimited field
# is the base64url key in both formats.
private_key="$(awk '/^(Private key|PrivateKey):/ { print $NF; exit }' <<<"$pair")"
public_key="$(awk '/^(Public key|Password)/ { print $NF; exit }' <<<"$pair")"
[[ -n "$private_key" && -n "$public_key" ]] || die "xray x25519 returned unexpected output"
short_id="$(openssl rand -hex 8)"

umask 077
{
  printf 'REALITY_PRIVATE_KEY=%q\n' "$private_key"
  printf 'REALITY_PUBLIC_KEY=%q\n' "$public_key"
  printf 'REALITY_SHORT_ID=%q\n' "$short_id"
  printf 'REALITY_TARGET=%q\n' "$target"
  printf 'REALITY_SERVER_NAME=%q\n' "$server_name"
} > "$key_file"
chmod 600 "$key_file"

cat > "$state_dir/reality-client-info.json" <<EOF
{"publicKey":"$public_key","shortId":"$short_id","target":"$target","serverName":"$server_name","fingerprint":"$fingerprint"}
EOF
chmod 600 "$state_dir/reality-client-info.json"
