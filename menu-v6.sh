#!/usr/bin/env bash
# This is an interactive UI: a rejected username, missing account, or cancelled
# action must return to the current menu rather than terminate the whole UI.
set -uo pipefail

# The stable command is a symlink in /usr/local/bin, so resolve it before
# locating the companion account-management scripts.
script_path="$(readlink -f -- "${BASH_SOURCE[0]}")"
script_dir="$(cd -- "$(dirname -- "$script_path")" && pwd)"
state_dir="${V6_STATE_DIR:-/etc/ssh-xray-websocket-v6}"

# GF visual language, kept terminal-safe: colour is disabled when output is
# redirected so account links and scripts remain clean plain text.
if [[ -t 1 && "${TERM:-dumb}" != dumb ]]; then
  RED=$'\033[0;31m'; GREEN=$'\033[0;32m'; YELLOW=$'\033[1;33m'; BLUE=$'\033[0;34m'; CYAN=$'\033[0;36m'; WHITE=$'\033[1;37m'; BOLD=$'\033[1m'; NC=$'\033[0m'
else
  RED= GREEN= YELLOW= BLUE= CYAN= WHITE= BOLD= NC=
fi

line() { printf '%b══════════════════════════════════════════════════════════════%b\n' "$CYAN" "$NC"; }
menu_title() { line; printf '                 %b%s%b\n' "$BOLD" "$1" "$NC"; line; }
item() { printf '  [%b%02d%b] %s\n' "$YELLOW" "$1" "$NC" "$2"; }
back_item() { printf '  [%b00%b] Back\n' "$YELLOW" "$NC"; }
pause() { echo; read -r -p 'Press Enter to continue... ' _; }
ask_account() { read -r -p 'Username: ' account; read -r -p 'Validity (days): ' validity; }
primary_domain() { jq -r '.primaryDomain' "$state_dir/routes.json"; }
load_service_options() { [[ -r "$state_dir/service-options.env" ]] && source "$state_dir/service-options.env"; }
load_runtime() { [[ -r "$state_dir/runtime.env" ]] && source "$state_dir/runtime.env"; export V6_CERT_FILE="${V6_CERT_FILE:-${V6_STORED_CERT_FILE:-}}" V6_KEY_FILE="${V6_KEY_FILE:-${V6_STORED_KEY_FILE:-}}"; }
pick_xray_account() { local protocol="$1" store; store="$state_dir/users/${protocol}.json"; mapfile -t names < <(jq -r '.[].name' "$store" 2>/dev/null); ((${#names[@]})) || { echo 'No accounts found.'; return 1; }; local i=1; for name in "${names[@]}"; do printf '  [%02d] %s\n' "$i" "$name"; ((i++)); done; echo '  [00] Back'; read -r -p '  ► Account: ' i; [[ "$i" =~ ^[0-9]+$ ]] && ((i>0 && i<=${#names[@]})) || return 1; account="${names[$((i-1))]}"; }

show_ports() {
  local domain ram cpu kernel
  domain="$(primary_domain 2>/dev/null || hostname -f 2>/dev/null || hostname)"
  ram="$(free -h 2>/dev/null | awk '/^Mem:/ {print $3 "/" $2}' || echo n/a)"
  cpu="$(awk -F': ' '/model name/ {print $2; exit}' /proc/cpuinfo 2>/dev/null || uname -m)"
  kernel="$(uname -r)"
  line
  printf '        %bFRIMPS MULTI-PROTOCOL VPN MANAGEMENT%b\n' "$BOLD" "$NC"
  printf '        %bSSH / XRAY / OPENVPN / HYSTERIA / WIREGUARD%b\n' "$GREEN" "$NC"
  line
  printf '  %bDomain:%b %-27s %bKernel:%b %s\n' "$WHITE" "$NC" "$domain" "$WHITE" "$NC" "$kernel"
  printf '  %bRAM:%b    %-27s %bCPU:%b %s\n' "$WHITE" "$NC" "$ram" "$WHITE" "$NC" "$cpu"
  printf '%b--------------------------- PUBLIC PORTS ---------------------------%b\n' "$CYAN" "$NC"
  printf '  %-15s %-19s %-15s %s\n' 'SSH:' '22, 143 TCP' 'VLESS/Trojan:' '443 TCP'
  printf '  %-15s %-19s %-15s %s\n' 'SSH Payload:' '80, 8080, 8880' 'Hysteria 2:' '443 UDP'
  printf '  %-15s %-19s %-15s %s\n' 'SSH WS TLS:' '443 / 2082 / 2086' 'OpenVPN:' '1194 TCP/UDP, 8433'
  printf '  %-15s %-19s %-15s %s\n' 'SlowDNS:' '53, 5300 UDP' 'WireGuard:' '4000 UDP'
  printf '  %-15s %-19s %-15s %s\n' 'ZiVPN:' '6000-19999 UDP' 'Hysteria 1:' '20000-50000 UDP'
  printf '  %-15s %-19s\n' 'UDP Custom:' 'remaining UDP ports'
  line
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
    clear; menu_title 'HYSTERIA 1 ACCOUNT MANAGEMENT'
    item 1 'Create Hysteria 1 account'
    item 2 'Renew Hysteria 1 account'
    item 3 'Delete Hysteria 1 account'
    item 4 'List Hysteria 1 accounts'
    item 5 'Edit Hysteria 1 speeds'
    back_item
    read -r -p '  ► Option: ' x
    case "$x" in
      1) ask_account; load_service_options; read -r -p 'Account password (Enter for generated password): ' password; V6_DOMAIN="$(primary_domain)" bash "$script_dir/hysteria1-accounts.sh" create "$account" "$validity" "${password:-$(openssl rand -hex 12)}"; unset password; pause ;;
      2) ask_account; bash "$script_dir/hysteria1-accounts.sh" renew "$account" "$validity"; pause ;;
      3) read -r -p 'Username: ' account; bash "$script_dir/hysteria1-accounts.sh" delete "$account"; pause ;;
      4) bash "$script_dir/hysteria1-accounts.sh" list; pause ;;
      5) read -r -p 'Upload Mbps: ' up; read -r -p 'Download Mbps: ' down; bash "$script_dir/hysteria1-accounts.sh" speed "$up" "$down"; pause ;;
      0) return ;;
      *) echo 'Invalid option.'; sleep 1 ;;
    esac
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
    menu_title 'ZIVPN ACCOUNT MANAGEMENT'
    item 1 'Install / reconfigure backend'
    item 2 'Create account'
    item 3 'Renew account'
    item 4 'Delete account'
    item 5 'List accounts'
    item 6 'Service status'
    back_item
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
maintenance_menu() { while true; do clear; echo '═══ FRIMPS MAINTENANCE ═══'; echo '  [1] Monitor active connections'; echo '  [2] Restart SSH services'; echo '  [3] Restart Xray services'; echo '  [4] Restart UDP services'; echo '  [5] Restart OpenVPN services'; echo '  [6] Restart WireGuard'; echo '  [7] Restart all Frimps services'; echo '  [8] Create managed-state backup'; echo '  [9] Remove expired managed accounts'; echo '  [10] Reboot server'; echo '  [0] Back'; read -r -p '  ► Option: ' x; case "$x" in 1) bash "$script_dir/maintenance-v6.sh" monitor; pause;; 2) bash "$script_dir/maintenance-v6.sh" restart ssh; pause;; 3) bash "$script_dir/maintenance-v6.sh" restart xray; pause;; 4) bash "$script_dir/maintenance-v6.sh" restart udp; pause;; 5) bash "$script_dir/maintenance-v6.sh" restart openvpn; pause;; 6) bash "$script_dir/maintenance-v6.sh" restart wireguard; pause;; 7) read -r -p 'Restart all managed services? [y/N] ' confirm; [[ "$confirm" =~ ^[Yy]$ ]] && bash "$script_dir/maintenance-v6.sh" restart all; pause;; 8) bash "$script_dir/maintenance-v6.sh" backup; pause;; 9) read -r -p 'Remove expired managed accounts? [y/N] ' confirm; [[ "$confirm" =~ ^[Yy]$ ]] && bash "$script_dir/maintenance-v6.sh" cleanup; pause;; 10) read -r -p 'Reboot server now? [y/N] ' confirm; [[ "$confirm" =~ ^[Yy]$ ]] && reboot; return;; 0) return;; *) echo 'Invalid option.'; sleep 1;; esac; done; }

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
  clear
  show_ports
  echo
  item 1 'SSH Account Management (SSH / Payload / SlowDNS)'
  item 2 'Xray Account Management (VLESS / Trojan / REALITY)'
  item 3 'Hysteria 1 Account Management (UDP)'
  item 4 'ZiVPN Account Management (UDP)'
  item 5 'OpenVPN Account Management (UDP / TCP / SSL / WS)'
  item 6 'WireGuard Account Management (UDP)'
  item 7 'Hysteria 2 Account Management (UDP)'
  item 8 'SlowDNS / Domain / Obfuscation Settings'
  item 9 'UDP Custom Management'
  item 10 'Service Status'
  item 11 'Validate Frimps State'
  item 12 'Advanced: Stage Remaining-Service Foundation'
  item 13 'System Utilities (BBR / Netflix)'
  item 14 'Maintenance (monitor / restart / backup / cleanup)'
  printf '  [%b00%b] %bExit%b\n' "$RED" "$NC" "$BOLD" "$NC"
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
    14) maintenance_menu ;;
    0|00) exit 0 ;;
    *) echo 'Invalid option.'; sleep 1 ;;
  esac
done
