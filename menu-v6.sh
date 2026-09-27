#!/usr/bin/env bash
set -euo pipefail

# The stable command is a symlink in /usr/local/bin, so resolve it before
# locating the companion account-management scripts.
script_path="$(readlink -f -- "${BASH_SOURCE[0]}")"
script_dir="$(cd -- "$(dirname -- "$script_path")" && pwd)"
state_dir="${V6_STATE_DIR:-/etc/ssh-xray-websocket-v6}"

pause() { read -r -p 'Press Enter to continue... ' _; }
ask_account() { read -r -p 'Username: ' account; read -r -p 'Validity (days): ' validity; }

show_ports() {
  clear
  cat <<'EOF'
════════════ SSH / XRAY V6 ════════════

SSH              22, 143 TCP
SSH Payload      80, 8080, 8880 TCP
SSH WS NTLS      80, 8080, 8880, 2082, 2086 TCP
SSH SSL          443 TCP
SSH WS TLS       443 TCP

VLESS TLS        443 TCP
VLESS Enc NTLS   80, 8080, 8880 TCP
VLESS REALITY    443 TCP
VLESS Vision     443 TCP
Trojan WS TLS    443 TCP, path /trojan

Hysteria 2       443 UDP
OpenVPN          1194 TCP/UDP, 8433 TCP
WireGuard        4000 UDP
SlowDNS          53, 5300 UDP
EOF
}

not_installed() {
  clear
  echo "═══ $1 ═══"
  echo
  echo 'This protocol is not installed or managed by v6 yet.'
  echo 'No accounts, ports, or legacy services were changed.'
  pause
}

status_menu() {
  clear
  echo '═══ V6 SERVICE STATUS ═══'
  echo
  for unit in ssh-xray-websocket-v6-dropbear ssh-xray-websocket-v6-sshws ssh-xray-websocket-v6-payloadgate ssh-xray-websocket-v6-tlsmux ssh-xray-websocket-v6-xray ssh-xray-websocket-v6-gfraw nginx haproxy; do
    printf '%-42s %s\n' "$unit" "$(systemctl is-active "$unit" 2>/dev/null || true)"
  done
  echo
  ss -ltn '( sport = :22 or sport = :80 or sport = :443 or sport = :8080 or sport = :8880 or sport = :2082 or sport = :2086 )' 2>/dev/null || true
  pause
}

xray_menu() {
  while true; do
    clear; echo '═══ XRAY MANAGEMENT ═══'
    select choice in 'VLESS accounts' 'Trojan accounts' 'REALITY server information' 'Back'; do
      case "$choice" in
        'VLESS accounts') vless_menu ;;
        'Trojan accounts') trojan_menu ;;
        'REALITY server information') [[ -s "$state_dir/reality-client-info.json" ]] && cat "$state_dir/reality-client-info.json" || echo 'REALITY keys have not been generated.'; pause ;;
        Back) return ;;
        *) echo 'Choose a listed option.' ;;
      esac
      break
    done
  done
}

vless_menu() {
  while true; do
    clear; echo '═══ VLESS ACCOUNT MANAGEMENT ═══'
    select choice in 'Create' 'Renew' 'Delete' 'List' 'Show links' 'Back'; do
      case "$choice" in
        Create) ask_account; "$script_dir/accounts.sh" vless create "$account" "$validity"; pause ;;
        Renew) ask_account; "$script_dir/accounts.sh" vless renew "$account" "$validity"; pause ;;
        Delete) read -r -p 'Username: ' account; "$script_dir/accounts.sh" vless delete "$account"; pause ;;
        List) "$script_dir/accounts.sh" vless list; pause ;;
        'Show links') read -r -p 'Username: ' account; "$script_dir/accounts.sh" vless links "$account"; pause ;;
        Back) return ;;
        *) echo 'Choose a listed option.' ;;
      esac
      break
    done
  done
}

trojan_menu() {
  while true; do
    clear; echo '═══ TROJAN ACCOUNT MANAGEMENT ═══'
    select choice in 'Create' 'Renew' 'Delete' 'List' 'Show link' 'Back'; do
      case "$choice" in
        Create) ask_account; "$script_dir/accounts.sh" trojan create "$account" "$validity"; pause ;;
        Renew) ask_account; "$script_dir/accounts.sh" trojan renew "$account" "$validity"; pause ;;
        Delete) read -r -p 'Username: ' account; "$script_dir/accounts.sh" trojan delete "$account"; pause ;;
        List) "$script_dir/accounts.sh" trojan list; pause ;;
        'Show link') read -r -p 'Username: ' account; "$script_dir/accounts.sh" trojan links "$account"; pause ;;
        Back) return ;;
        *) echo 'Choose a listed option.' ;;
      esac
      break
    done
  done
}

ssh_menu() {
  while true; do
    clear; echo '═══ SSH ACCOUNT MANAGEMENT ═══'
    select choice in 'Create' 'Renew' 'Delete from numbered list' 'List' 'Back'; do
      case "$choice" in
        Create) ask_account; "$script_dir/ssh-accounts.sh" create "$account" "$validity"; pause ;;
        Renew) ask_account; "$script_dir/ssh-accounts.sh" renew "$account" "$validity"; pause ;;
        'Delete from numbered list') "$script_dir/ssh-accounts.sh" choose-delete; pause ;;
        List) "$script_dir/ssh-accounts.sh" list; pause ;;
        Back) return ;;
        *) echo 'Choose a listed option.' ;;
      esac
      break
    done
  done
}

while true; do
  show_ports
  echo
  select choice in 'SSH management' 'Xray management' 'OpenVPN' 'Hysteria 1' 'Hysteria 2' 'ZiVPN' 'WireGuard' 'SlowDNS / domain' 'Service status' 'Validate v6 state' 'Exit'; do
    case "$choice" in
      'SSH management') ssh_menu ;;
      'Xray management') xray_menu ;;
      OpenVPN) not_installed 'OPENVPN MANAGEMENT' ;;
      'Hysteria 1') not_installed 'HYSTERIA 1 MANAGEMENT' ;;
      'Hysteria 2') not_installed 'HYSTERIA 2 MANAGEMENT' ;;
      ZiVPN) not_installed 'ZIVPN MANAGEMENT' ;;
      WireGuard) not_installed 'WIREGUARD MANAGEMENT' ;;
      'SlowDNS / domain') not_installed 'SLOWDNS / DOMAIN MANAGEMENT' ;;
      'Service status') status_menu ;;
      'Validate v6 state') "$script_dir/validate-v6.sh"; pause ;;
      Exit) exit 0 ;;
      *) echo 'Choose a listed option.' ;;
    esac
    break
  done
done
