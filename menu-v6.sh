#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
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
  select choice in 'SSH accounts' 'VLESS accounts' 'Trojan accounts' 'REALITY server information' 'Validate v6 state' 'Exit'; do
    case "$choice" in
      'SSH accounts') ssh_menu ;;
      'VLESS accounts') vless_menu ;;
      'Trojan accounts') trojan_menu ;;
      'REALITY server information')
        [[ -s "$state_dir/reality-client-info.json" ]] && cat "$state_dir/reality-client-info.json" || echo 'REALITY keys have not been generated.'
        pause ;;
      'Validate v6 state') "$script_dir/validate-v6.sh"; pause ;;
      Exit) exit 0 ;;
      *) echo 'Choose a listed option.' ;;
    esac
    break
  done
done
