#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
domain="${V6_DOMAIN:-}"

die() { echo "v6 test installer: $*" >&2; exit 1; }
[[ "${EUID}" -eq 0 ]] || die "run as root"
[[ -n "$domain" ]] || die "set V6_DOMAIN to the primary hostname"

for command in jq xray haproxy nginx go openssl; do
  command -v "$command" >/dev/null 2>&1 || die "missing dependency: $command"
done

"$script_dir/install-v6.sh"
if [[ -n "${V6_REALITY_TARGET:-}" || -n "${V6_REALITY_SERVER_NAME:-}" ]]; then
  [[ -n "${V6_REALITY_TARGET:-}" && -n "${V6_REALITY_SERVER_NAME:-}" ]] || die "set both V6_REALITY_TARGET and V6_REALITY_SERVER_NAME"
  "$script_dir/generate-reality-keys.sh"
fi
"$script_dir/render-backends.sh"
"$script_dir/render-routing.sh"
"$script_dir/validate-v6.sh"
"$script_dir/stage-services.sh"
"$script_dir/protocol-health-v6.sh" --staged

cat <<'EOF'

v6 test-VPS staging is complete.

No public listener has been enabled. Review the migration report and use the
TCP 443 preflight before designing a cutover around the actual legacy owner:

  ./v6/migration-report.sh
  ./v6/preflight-cutover.sh
EOF
