#!/usr/bin/env bash
# This is an interactive UI: a rejected username, missing account, or cancelled
# action must return to the current menu rather than terminate the whole UI.
set -uo pipefail

# The stable command is a symlink in /usr/local/bin, so resolve it before
# locating the companion account-management scripts.
script_path="$(readlink -f -- "${BASH_SOURCE[0]}")"
script_dir="$(cd -- "$(dirname -- "$script_path")" && pwd)"
state_dir="${V6_STATE_DIR:-/etc/ssh-xray-websocket-v6}"

pause() { read -r -p 'Press Enter to continue... ' _; }
ask_account() { read -r -p 'Username: ' account; read -r -p 'Validity (days): ' validity; }
primary_domain() { jq -r '.primaryDomain' "$state_dir/routes.json"; }
load_service_options() { [[ -r "$state_dir/service-options.env" ]] && source "$state_dir/service-options.env"; }
load_runtime() { [[ -r "$state_dir/runtime.env" ]] && source "$state_dir/runtime.env"; export V6_CERT_FILE="${V6_CERT_FILE:-${V6_STORED_CERT_FILE:-}}" V6_KEY_FILE="${V6_KEY_FILE:-${V6_STORED_KEY_FILE:-}}"; }
pick_xray_account() { local protocol="$1" store; store="$state_dir/users/${protocol}.json"; mapfile -t names < <(jq -r '.[].name' "$store" 2>/dev/null); ((${#names[@]})) || { echo 'No accounts found.'; return 1; }; local i=1; for name in "${names[@]}"; do printf '  [%02d] %s\n' "$i" "$name"; ((i++)); done; echo '  [00] Back'; read -r -p '  ► Account: ' i; [[ "$i" =~ ^[0-9]+$ ]] && ((i>0 && i<=${#names[@]})) || return 1; account="${names[$((i-1))]}"; }

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
ZiVPN            6000-19999 UDP
Hysteria 1       20000-50000 UDP
UDP Custom       remaining UDP only
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
  for unit in ssh-xray-websocket-v6-dropbear ssh-xray-websocket-v6-sshws ssh-xray-websocket-v6-payloadgate ssh-xray-websocket-v6-tlsmux ssh-xray-websocket-v6-xray ssh-xray-websocket-v6-gfraw ssh-xray-websocket-v6-udp-routing frimps-openvpn-udp frimps-openvpn-tcp frimps-openvpn-gateway frimps-openvpn-stunnel frimps-openvpn-bshield hysteria1-server hysteria2-server wg-quick@wg0 frimps-slowdns zivpn frimps-badvpn frimps-udp-custom nginx haproxy; do
    printf '%-42s %s\n' "$unit" "$(systemctl is-active "$unit" 2>/dev/null || true)"
  done
  echo
  ss -ltn '( sport = :22 or sport = :80 or sport = :443 or sport = :8080 or sport = :8880 or sport = :2082 or sport = :2086 )' 2>/dev/null || true
  pause
}

remaining_services_menu() {
  clear
  echo '═══ REMAINING SERVICE FOUNDATION ═══'
  echo
  echo 'This stages the ordered UDP policy, OpenVPN baseline configurations,'
  echo 'and a non-destructive WireGuard base configuration. It does not start'
  echo 'or claim Hysteria, ZiVPN, SlowDNS, or UDP-Custom without reviewed binaries'
  echo 'and authenticated configurations.'
  read -r -p 'Stage these foundations now? [y/N] ' reply
  [[ "$reply" =~ ^[Yy]$ ]] || return
  V6_DOMAIN="$(jq -r '.primaryDomain' "$state_dir/routes.json")" "$script_dir/install-remaining-services.sh"
  pause
}

wireguard_menu() {
  while true; do
    clear; echo '═══ WIREGUARD MANAGEMENT ═══'
    select choice in 'Create peer' 'Renew peer' 'Delete peer' 'List peers' 'Show client config' 'Show WireGuard link' 'Back'; do
      [[ "$REPLY" == 0 ]] && return
      case "$choice" in
        'Create peer') ask_account; "$script_dir/wireguard-accounts.sh" create "$account" "$validity"; pause ;;
        'Renew peer') ask_account; "$script_dir/wireguard-accounts.sh" renew "$account" "$validity"; pause ;;
        'Delete peer') read -r -p 'Username: ' account; "$script_dir/wireguard-accounts.sh" delete "$account"; pause ;;
        'List peers') "$script_dir/wireguard-accounts.sh" list; pause ;;
        'Show client config') read -r -p 'Username: ' account; "$script_dir/wireguard-accounts.sh" config "$account"; pause ;;
        'Show WireGuard link') read -r -p 'Username: ' account; "$script_dir/wireguard-accounts.sh" link "$account"; pause ;;
        Back) return ;;
        *) echo 'Choose a listed option.' ;;
      esac
      break
    done
  done
}

openvpn_menu() {
  while true; do
    clear; echo '═══ OPENVPN MANAGEMENT ═══'
    select choice in 'Configure service' 'Create account' 'Renew account' 'Delete account' 'List accounts' 'Show UDP profile' 'Show TCP profile' 'Show universal profile' 'Back'; do
      [[ "$REPLY" == 0 ]] && return
      case "$choice" in
        'Configure service') V6_DOMAIN="$(primary_domain)" "$script_dir/openvpn-install.sh"; pause ;;
        'Create account') ask_account; V6_DOMAIN="$(primary_domain)" "$script_dir/openvpn-accounts.sh" create "$account" "$validity"; pause ;;
        'Renew account') ask_account; "$script_dir/openvpn-accounts.sh" renew "$account" "$validity"; pause ;;
        'Delete account') read -r -p 'Username: ' account; "$script_dir/openvpn-accounts.sh" delete "$account"; pause ;;
        'List accounts') "$script_dir/openvpn-accounts.sh" list; pause ;;
        'Show UDP profile') read -r -p 'Username: ' account; "$script_dir/openvpn-accounts.sh" profile "$account" udp; pause ;;
        'Show TCP profile') read -r -p 'Username: ' account; "$script_dir/openvpn-accounts.sh" profile "$account" tcp; pause ;;
        'Show universal profile') cat /etc/openvpn/client-template.ovpn 2>/dev/null || echo 'Configure OpenVPN first.'; pause ;;
        Back) return ;;
        *) echo 'Choose a listed option.' ;;
      esac
      break
    done
  done
}

hysteria1_menu() {
  while true; do
    clear; echo '═══ HYSTERIA 1 MANAGEMENT ═══'
    select choice in 'Configure installed sing-box backend' 'Create account' 'Renew account' 'Delete account' 'List accounts' 'Show link' 'Back'; do
      [[ "$REPLY" == 0 ]] && return
      case "$choice" in
        'Configure installed sing-box backend') load_service_options; V6_DOMAIN="$(primary_domain)" "$script_dir/hysteria1-install.sh"; pause ;;
        'Create account') ask_account; load_service_options; read -r -p 'Account password (Enter for generated password): ' password; V6_DOMAIN="$(primary_domain)" "$script_dir/hysteria1-accounts.sh" create "$account" "$validity" "${password:-$(openssl rand -hex 12)}"; unset password; pause ;;
        'Renew account') ask_account; "$script_dir/hysteria1-accounts.sh" renew "$account" "$validity"; pause ;;
        'Delete account') read -r -p 'Username: ' account; "$script_dir/hysteria1-accounts.sh" delete "$account"; pause ;;
        'List accounts') "$script_dir/hysteria1-accounts.sh" list; pause ;;
        'Show link') read -r -p 'Username: ' account; "$script_dir/hysteria1-accounts.sh" uri "$account"; pause ;;
        Back) return ;;
        *) echo 'Choose a listed option.' ;;
      esac
      break
    done
  done
}

hysteria2_menu() {
  while true; do
    clear; echo '═══ HYSTERIA 2 MANAGEMENT ═══'
    select choice in 'Configure installed Hysteria backend' 'Create account' 'Renew account' 'Delete account' 'List accounts' 'Show link' 'Back'; do
      [[ "$REPLY" == 0 ]] && return
      case "$choice" in
        'Configure installed Hysteria backend') load_service_options; V6_DOMAIN="$(primary_domain)" "$script_dir/hysteria2-install.sh"; pause ;;
        'Create account') ask_account; load_service_options; V6_DOMAIN="$(primary_domain)" "$script_dir/hysteria2-accounts.sh" create "$account" "$validity"; pause ;;
        'Renew account') ask_account; "$script_dir/hysteria2-accounts.sh" renew "$account" "$validity"; pause ;;
        'Delete account') read -r -p 'Username: ' account; "$script_dir/hysteria2-accounts.sh" delete "$account"; pause ;;
        'List accounts') "$script_dir/hysteria2-accounts.sh" list; pause ;;
        'Show link') read -r -p 'Username: ' account; "$script_dir/hysteria2-accounts.sh" uri "$account"; pause ;;
        Back) return ;;
        *) echo 'Choose a listed option.' ;;
      esac
      break
    done
  done
}

settings_menu() {
  clear
  echo '═══ DOMAIN / SLOWDNS / OBFUSCATION SETTINGS ═══'
  echo
  bash "$script_dir/service-options-v6.sh"
  read -r -p 'Install/enable SlowDNS using these settings now? [y/N] ' x
  [[ "$x" =~ ^[Yy]$ ]] && slowdns_menu
  pause
}

zivpn_menu() {
  while true; do
    clear
    echo '═══ ZIVPN ACCOUNT MANAGEMENT ═══'
    echo '  [1] Install / reconfigure backend'
    echo '  [2] Create account'
    echo '  [3] Renew account'
    echo '  [4] Delete account'
    echo '  [5] List accounts'
    echo '  [6] Service status'
    echo '  [0] Back'
    read -r -p '  ► Option: ' x
    case "$x" in
      1) load_runtime; load_service_options; V6_DOMAIN="$(primary_domain)" bash "$script_dir/zivpn-install.sh"; systemctl enable --now zivpn.service; pause ;;
      2) read -r -p 'Password / username: ' account; read -r -p 'Validity (days): ' validity; V6_DOMAIN="$(primary_domain)" bash "$script_dir/zivpn-accounts.sh" create "$account" "$validity"; pause ;;
      3) read -r -p 'Password / username: ' account; read -r -p 'Validity (days): ' validity; V6_DOMAIN="$(primary_domain)" bash "$script_dir/zivpn-accounts.sh" renew "$account" "$validity"; pause ;;
      4) read -r -p 'Password / username: ' account; bash "$script_dir/zivpn-accounts.sh" delete "$account"; pause ;;
      5) bash "$script_dir/zivpn-accounts.sh" list; pause ;;
      6) systemctl --no-pager --full status zivpn.service; pause ;;
      0) return ;;
      *) echo 'Invalid option.'; sleep 1 ;;
    esac
  done
}
slowdns_menu() { clear; bash "$script_dir/slowdns-install.sh"; read -r -p 'Enable SlowDNS now? [y/N] ' x; [[ "$x" =~ ^[Yy]$ ]] && systemctl enable --now frimps-slowdns.service; pause; }
udp_custom_menu() { clear; bash "$script_dir/udp-custom-install.sh"; read -r -p 'Enable UDP Custom now? [y/N] ' x; [[ "$x" =~ ^[Yy]$ ]] && systemctl enable --now frimps-badvpn.service frimps-udp-custom.service; pause; }
utilities_menu() { while true; do clear; echo '═══ SYSTEM UTILITIES ═══'; echo '  [1] BBR status'; echo '  [2] Enable native kernel BBR'; echo '  [3] Netflix / streaming region check'; echo '  [0] Back'; read -r -p '  ► Option: ' x; case "$x" in 1) bash "$script_dir/utilities-v6.sh" status; pause;; 2) bash "$script_dir/utilities-v6.sh" enable-bbr; pause;; 3) bash "$script_dir/utilities-v6.sh" netflix; pause;; 0) return;; *) echo 'Invalid option.'; sleep 1;; esac; done; }

xray_menu() {
  while true; do
    clear; echo '═══ XRAY MANAGEMENT ═══'
    select choice in 'VLESS accounts' 'Trojan accounts' 'REALITY server information' 'Back'; do
      [[ "$REPLY" == 0 ]] && return
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
      [[ "$REPLY" == 0 ]] && return
      case "$choice" in
        Create) ask_account; "$script_dir/accounts.sh" vless create "$account" "$validity"; pause ;;
        Renew) ask_account; "$script_dir/accounts.sh" vless renew "$account" "$validity"; pause ;;
        Delete) read -r -p 'Username: ' account; "$script_dir/accounts.sh" vless delete "$account"; pause ;;
        List) "$script_dir/accounts.sh" vless list; pause ;;
        'Show links') pick_xray_account vless && "$script_dir/accounts.sh" vless links "$account"; pause ;;
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
      [[ "$REPLY" == 0 ]] && return
      case "$choice" in
        Create) ask_account; "$script_dir/accounts.sh" trojan create "$account" "$validity"; pause ;;
        Renew) ask_account; "$script_dir/accounts.sh" trojan renew "$account" "$validity"; pause ;;
        Delete) read -r -p 'Username: ' account; "$script_dir/accounts.sh" trojan delete "$account"; pause ;;
        List) "$script_dir/accounts.sh" trojan list; pause ;;
        'Show link') pick_xray_account trojan && "$script_dir/accounts.sh" trojan links "$account"; pause ;;
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
      [[ "$REPLY" == 0 ]] && return
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
  load_runtime
  show_ports
  echo
  echo '  [01] SSH Account Management'
  echo '  [02] Xray Account Management'
  echo '  [03] Hysteria 1 Account Management'
  echo '  [04] ZiVPN Account Management'
  echo '  [05] OpenVPN Account Management'
  echo '  [06] WireGuard Account Management'
  echo '  [07] Hysteria 2 Account Management'
  echo '  [08] SlowDNS / Domain / Obfuscation Settings'
  echo '  [09] UDP Custom Management'
  echo '  [10] Service Status'
  echo '  [11] Validate Frimps State'
  echo '  [12] Advanced: Stage Remaining-Service Foundation'
  echo '  [13] System Utilities (BBR / Netflix)'
  echo '  [00] Exit'
  echo
  read -r -p '  ► Select an option: ' choice
  case "$choice" in
    1|01) ssh_menu ;;
    2|02) xray_menu ;;
    3|03) hysteria1_menu ;;
    4|04) zivpn_menu ;;
    5|05) openvpn_menu ;;
    6|06) wireguard_menu ;;
    7|07) hysteria2_menu ;;
    8|08) settings_menu ;;
    9|09) udp_custom_menu ;;
    10) status_menu ;;
    11) "$script_dir/validate-v6.sh"; pause ;;
    12) remaining_services_menu ;;
    13) utilities_menu ;;
    0|00) exit 0 ;;
    *) echo 'Invalid option.'; sleep 1 ;;
  esac
done
