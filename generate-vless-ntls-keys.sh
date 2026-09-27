#!/usr/bin/env bash
set -euo pipefail

state_dir="${V6_STATE_DIR:-/etc/ssh-xray-websocket-v6}"
key_file="$state_dir/vless-encryption.env"

require_root() {
  if [[ "${EUID}" -ne 0 ]]; then
    echo "Run as root." >&2
    exit 1
  fi
}

require_root
mkdir -p -m 700 "$state_dir"

if [[ -s "$key_file" ]]; then
  # shellcheck disable=SC1090
  source "$key_file"
  if [[ "${VLESS_NTLS_DECRYPTION:-}" == mlkem768x25519plus.* && "${VLESS_NTLS_ENCRYPTION:-}" == mlkem768x25519plus.* ]]; then
    exit 0
  fi
  echo "Existing VLESS Encryption material is invalid: $key_file" >&2
  exit 1
fi

command -v xray >/dev/null 2>&1 || { echo "xray is required before generating VLESS Encryption material." >&2; exit 1; }
command -v jq >/dev/null 2>&1 || { echo "jq is required before generating VLESS Encryption material." >&2; exit 1; }

pair="$(xray vlessenc)"
decryption="$(jq -r '.decryption // empty' <<<"$pair")"
encryption="$(jq -r '.encryption // empty' <<<"$pair")"

if [[ "$decryption" != mlkem768x25519plus.* || "$encryption" != mlkem768x25519plus.* ]]; then
  echo "xray vlessenc returned an unexpected VLESS Encryption pair." >&2
  exit 1
fi

umask 077
{
  printf 'VLESS_NTLS_DECRYPTION=%q\n' "$decryption"
  printf 'VLESS_NTLS_ENCRYPTION=%q\n' "$encryption"
} > "$key_file"
chmod 600 "$key_file"
