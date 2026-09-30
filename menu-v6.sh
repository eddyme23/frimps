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
  RED=$'\033[1;31m'; GREEN=$'\033[1;32m'; YELLOW=$'\033[1;33m'; BLUE=$'\033[1;34m'; CYAN=$'\033[1;36m'; WHITE=$'\033[1;37m'; BOLD=$'\033[1m'; NC=$'\033[0m'
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
pick_account_store() { local store="$1" field="${2:-name}" label="${3:-Account}" i; mapfile -t names < <(jq -r ".[] | .$field" "$store" 2>/dev/null); ((${#names[@]})) || { echo "No $label accounts found."; return 1; }; menu_title "SELECT $label ACCOUNT"; for i in "${!names[@]}"; do item "$((i+1))" "${names[$i]}"; done; back_item; read -r -p '  ► Select account: ' i; [[ "$i" =~ ^[0-9]+$ ]] && ((i>0 && i<=${#names[@]})) || return 1; account="${names[$((i-1))]}"; }
pick_xray_account() { pick_account_store "$state_dir/users/$1.json" name "${1^^}"; }

show_ports() {
  local domain os_name arch cores now ram cpu buffer idle idle2 total total2 work
  domain="$(primary_domain 2>/dev/null || hostname -f 2>/dev/null || hostname)"
  os_name="$(. /etc/os-release 2>/dev/null; printf '%s %s' "${ID:-Linux}" "${VERSION_ID:-}")"
  os_name="${os_name^^}"; arch="$(uname -m)"; cores="$(nproc 2>/dev/null || echo '?')"; now="$(date -u '+%H:%M GMT')"
  ram="$(free 2>/dev/null | awk '/^Mem:/ {printf "%.1f%%", ($3/$2)*100}' || echo n/a)"
  buffer="$(free -m 2>/dev/null | awk '/^Mem:/ {print ($6+$7) "M"}' || echo n/a)"
  # A short second sample avoids top-format and locale dependencies.
  read -r total idle < <(awk '/^cpu / {t=0; for(i=2;i<=NF;i++) t+=$i; print t,$5; exit}' /proc/stat)
  sleep 0.16
  read -r total2 idle2 < <(awk '/^cpu / {t=0; for(i=2;i<=NF;i++) t+=$i; print t,$5; exit}' /proc/stat)
  work=$((total2-total)); ((work>0)) && cpu="$(awk -v i="$idle2" -v p="$idle" -v t="$work" 'BEGIN {printf "%.1f%%", 100-(i-p)*100/t}')" || cpu='n/a'
  line
  printf '              %b>>>>  🐉  FRIMPS  ★  PLUS  🐉  <<<<%b\n' "$YELLOW" "$NC"
  line
  printf '  %bOS:%b   %-18s  %bArch:%b  %-14s  %bCores:%b  %s\n' "$WHITE" "$NC" "$os_name" "$WHITE" "$NC" "$arch" "$WHITE" "$NC" "$cores"
  printf '  %bDomain:%b %-18s  %bTime:%b  %-14s  %bStatus:%b %bONLINE%b\n' "$WHITE" "$NC" "$domain" "$WHITE" "$NC" "$now" "$WHITE" "$NC" "$GREEN" "$NC"
  printf '%b--------------------------- PROTOCOL PORTS --------------------------%b\n' "$RED" "$NC"
  printf '  %b•%-1s %-12s %-22s %b•%-1s %-14s %s%b\n' "$WHITE" "$NC" 'SSH:' '22, 143' "$WHITE" "$NC" 'System-DNS:' '53'
  printf '  %b•%-1s %-12s %-22s %b•%-1s %-14s %s%b\n' "$WHITE" "$NC" 'Dropbear:' '143' "$WHITE" "$NC" 'WEB-Nginx:' '80 / 443'
  printf '  %b•%-1s %-12s %-22s %b•%-1s %-14s %s%b\n' "$WHITE" "$NC" 'SSL:' '443' "$WHITE" "$NC" 'SSH WS TLS:' '443'
  printf '  %b•%-1s %-12s %-22s %b•%-1s %-14s %s%b\n' "$WHITE" "$NC" 'SSH Payload:' '80, 8080, 8880' "$WHITE" "$NC" 'VLESS/Trojan:' '443'
  printf '  %b•%-1s %-12s %-22s %b•%-1s %-14s %s%b\n' "$WHITE" "$NC" 'SSH WS:' '2082, 2086' "$WHITE" "$NC" 'BadVPN:' '7300'
  printf '  %b•%-1s %-12s %-22s %b•%-1s %-14s %s%b\n' "$WHITE" "$NC" 'Xray NTLS:' '80, 8080, 8880' "$WHITE" "$NC" 'Hysteria 2:' '443 UDP'
  printf '  %b•%-1s %-12s %-22s %b•%-1s %-14s %s%b\n' "$WHITE" "$NC" 'Hysteria 1:' '20000-50000' "$WHITE" "$NC" 'ZiVPN:' '6000-19999'
  printf '  %b•%-1s %-12s %-22s %b•%-1s %-14s %s%b\n' "$WHITE" "$NC" 'UDPCustom:' 'remaining UDP' "$WHITE" "$NC" 'SlowDNS:' '53, 5300'
  printf '  %b•%-1s %-12s %-22s %b•%-1s %-14s %s%b\n' "$WHITE" "$NC" 'OpenVPN:' '1194 TCP/UDP' "$WHITE" "$NC" 'OVPN SSL:' '8433'
  printf '  %b•%-1s %-12s %-22s %b•%-1s %-14s %s%b\n' "$WHITE" "$NC" 'OVPN WS:' '80, 8080, 8880' "$WHITE" "$NC" 'WireGuard:' '4000 UDP'
  printf '%b-------------------------- SYSTEM RESOURCES -------------------------%b\n' "$RED" "$NC"
  printf '  %bRAM Used:%b  %-15s  %bCPU Used:%b  %-13s  %bBuffer:%b  %s\n' "$WHITE" "$NC" "$ram" "$WHITE" "$NC" "$cpu" "$WHITE" "$NC" "$buffer"
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
    clear; menu_title 'WIREGUARD ACCOUNT MANAGEMENT'
    item 1 'Create WireGuard account'; item 2 'Renew WireGuard account'; item 3 'Delete WireGuard account'; item 4 'List WireGuard accounts'; item 5 'Show WireGuard link'; item 6 'Show WireGuard client config'; item 7 'Remove expired accounts'; back_item
    read -r -p '  ► Option: ' x
    case "$x" in
      1) ask_account; bash "$script_dir/wireguard-accounts.sh" create "$account" "$validity"; pause ;;
      2) pick_account_store "$state_dir/wireguard-users.json" name WireGuard && { read -r -p 'Validity (days): ' validity; bash "$script_dir/wireguard-accounts.sh" renew "$account" "$validity"; }; pause ;;
      3) pick_account_store "$state_dir/wireguard-users.json" name WireGuard && bash "$script_dir/wireguard-accounts.sh" delete "$account"; pause ;;
      4) bash "$script_dir/wireguard-accounts.sh" list; pause ;;
      5) pick_account_store "$state_dir/wireguard-users.json" name WireGuard && bash "$script_dir/wireguard-accounts.sh" link "$account"; pause ;;
      6) pick_account_store "$state_dir/wireguard-users.json" name WireGuard && bash "$script_dir/wireguard-accounts.sh" config "$account"; pause ;;
      7) bash "$script_dir/wireguard-accounts.sh" cleanup; pause ;;
      0) return ;; *) echo 'Invalid option.'; sleep 1 ;;
    esac
  done
}

openvpn_menu() {
  while true; do
    clear; menu_title 'OPENVPN ACCOUNT MANAGEMENT'
    item 1 'Create OpenVPN account'; item 2 'Renew OpenVPN account'; item 3 'Delete OpenVPN account'; item 4 'List OpenVPN accounts'; item 5 'Show UDP profile'; item 6 'Show TCP profile'; item 7 'Show universal profile'; back_item
    read -r -p '  ► Option: ' x
    case "$x" in
      1) ask_account; V6_DOMAIN="$(primary_domain)" bash "$script_dir/openvpn-accounts.sh" create "$account" "$validity"; pause ;;
      2) pick_account_store "$state_dir/openvpn-users.json" name OpenVPN && { read -r -p 'Validity (days): ' validity; bash "$script_dir/openvpn-accounts.sh" renew "$account" "$validity"; }; pause ;;
      3) pick_account_store "$state_dir/openvpn-users.json" name OpenVPN && bash "$script_dir/openvpn-accounts.sh" delete "$account"; pause ;;
      4) bash "$script_dir/openvpn-accounts.sh" list; pause ;;
      5) pick_account_store "$state_dir/openvpn-users.json" name OpenVPN && bash "$script_dir/openvpn-accounts.sh" profile "$account" udp; pause ;;
      6) pick_account_store "$state_dir/openvpn-users.json" name OpenVPN && bash "$script_dir/openvpn-accounts.sh" profile "$account" tcp; pause ;;
      7) cat /etc/openvpn/client-template.ovpn 2>/dev/null || echo 'OpenVPN is not installed.'; pause ;;
      0) return ;; *) echo 'Invalid option.'; sleep 1 ;;
    esac
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
    clear; menu_title 'HYSTERIA 2 ACCOUNT MANAGEMENT'
    item 1 'Create Hysteria 2 account'; item 2 'Renew Hysteria 2 account'; item 3 'Delete Hysteria 2 account'; item 4 'List Hysteria 2 accounts'; item 5 'Show Hysteria 2 link'; back_item
    read -r -p '  ► Option: ' x
    case "$x" in
      1) ask_account; load_service_options; V6_DOMAIN="$(primary_domain)" bash "$script_dir/hysteria2-accounts.sh" create "$account" "$validity"; pause ;;
      2) pick_account_store "$state_dir/hysteria2-users.json" name 'Hysteria 2' && { read -r -p 'Validity (days): ' validity; bash "$script_dir/hysteria2-accounts.sh" renew "$account" "$validity"; }; pause ;;
      3) pick_account_store "$state_dir/hysteria2-users.json" name 'Hysteria 2' && bash "$script_dir/hysteria2-accounts.sh" delete "$account"; pause ;;
      4) bash "$script_dir/hysteria2-accounts.sh" list; pause ;;
      5) pick_account_store "$state_dir/hysteria2-users.json" name 'Hysteria 2' && bash "$script_dir/hysteria2-accounts.sh" uri "$account"; pause ;;
      0) return ;; *) echo 'Invalid option.'; sleep 1 ;;
    esac
  done
}

settings_menu() {
  clear
  menu_title 'DOMAIN / OBFUSCATION SETTINGS'
  echo
  bash "$script_dir/service-options-v6.sh"
  pause
}

zivpn_menu() {
  while true; do
    clear
    menu_title 'ZIVPN ACCOUNT MANAGEMENT'
    item 1 'Create account'
    item 2 'Renew account'
    item 3 'Delete account'
    item 4 'List accounts'
    item 5 'Service status'
    back_item
    read -r -p '  ► Option: ' x
    case "$x" in
      1) read -r -p 'Password / username: ' account; read -r -p 'Validity (days): ' validity; V6_DOMAIN="$(primary_domain)" bash "$script_dir/zivpn-accounts.sh" create "$account" "$validity"; pause ;;
      2) pick_account_store "$state_dir/zivpn-users.json" password ZiVPN && { read -r -p 'Validity (days): ' validity; V6_DOMAIN="$(primary_domain)" bash "$script_dir/zivpn-accounts.sh" renew "$account" "$validity"; }; pause ;;
      3) pick_account_store "$state_dir/zivpn-users.json" password ZiVPN && bash "$script_dir/zivpn-accounts.sh" delete "$account"; pause ;;
      4) bash "$script_dir/zivpn-accounts.sh" list; pause ;;
      5) systemctl --no-pager --full status zivpn.service; pause ;;
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
    clear; menu_title 'XRAY ACCOUNT MANAGEMENT'; item 1 'VLESS accounts'; item 2 'Trojan accounts'; item 3 'REALITY server information'; back_item
    read -r -p '  ► Option: ' x
    case "$x" in 1) vless_menu;; 2) trojan_menu;; 3) [[ -s "$state_dir/reality-client-info.json" ]] && cat "$state_dir/reality-client-info.json" || echo 'REALITY keys have not been generated.'; pause;; 0) return;; *) echo 'Invalid option.'; sleep 1;; esac
  done
}

vless_menu() {
  while true; do
    clear; menu_title 'VLESS ACCOUNT MANAGEMENT'; item 1 'Create account'; item 2 'Renew account'; item 3 'Delete account'; item 4 'List accounts'; item 5 'Show config links'; back_item
    read -r -p '  ► Option: ' x
    case "$x" in 1) ask_account; bash "$script_dir/accounts.sh" vless create "$account" "$validity"; pause;; 2) pick_xray_account vless && { read -r -p 'Validity (days): ' validity; bash "$script_dir/accounts.sh" vless renew "$account" "$validity"; }; pause;; 3) pick_xray_account vless && bash "$script_dir/accounts.sh" vless delete "$account"; pause;; 4) bash "$script_dir/accounts.sh" vless list; pause;; 5) pick_xray_account vless && bash "$script_dir/accounts.sh" vless links "$account"; pause;; 0) return;; *) echo 'Invalid option.'; sleep 1;; esac
  done
}

trojan_menu() {
  while true; do
    clear; menu_title 'TROJAN ACCOUNT MANAGEMENT'; item 1 'Create account'; item 2 'Renew account'; item 3 'Delete account'; item 4 'List accounts'; item 5 'Show config link'; back_item
    read -r -p '  ► Option: ' x
    case "$x" in 1) ask_account; bash "$script_dir/accounts.sh" trojan create "$account" "$validity"; pause;; 2) pick_xray_account trojan && { read -r -p 'Validity (days): ' validity; bash "$script_dir/accounts.sh" trojan renew "$account" "$validity"; }; pause;; 3) pick_xray_account trojan && bash "$script_dir/accounts.sh" trojan delete "$account"; pause;; 4) bash "$script_dir/accounts.sh" trojan list; pause;; 5) pick_xray_account trojan && bash "$script_dir/accounts.sh" trojan links "$account"; pause;; 0) return;; *) echo 'Invalid option.'; sleep 1;; esac
  done
}

ssh_menu() {
  while true; do
    clear; menu_title 'SSH ACCOUNT MANAGEMENT'; item 1 'Create SSH account'; item 2 'Renew SSH account'; item 3 'Delete SSH account'; item 4 'List SSH accounts'; item 5 'SlowDNS / UDP Custom supporting service status'; back_item
    read -r -p '  ► Option: ' x
    case "$x" in 1) ask_account; bash "$script_dir/ssh-accounts.sh" create "$account" "$validity"; pause;; 2) ask_account; bash "$script_dir/ssh-accounts.sh" renew "$account" "$validity"; pause;; 3) bash "$script_dir/ssh-accounts.sh" choose-delete; pause;; 4) bash "$script_dir/ssh-accounts.sh" list; pause;; 5) systemctl --no-pager --full status frimps-slowdns.service frimps-badvpn.service frimps-udp-custom.service; pause;; 0) return;; *) echo 'Invalid option.'; sleep 1;; esac
  done
}

while true; do
  load_runtime
  clear
  show_ports
  echo
  item 1 'SSH Account Management (SSH / SlowDNS / UDP Custom)'
  item 2 'Xray Account Management (VLESS / Trojan / REALITY)'
  item 3 'Hysteria 1 Account Management (UDP)'
  item 4 'ZiVPN Account Management (UDP)'
  item 5 'Monitor Active Connections'
  item 6 'Service Controls (restart protocols)'
  item 7 'Create Frimps Backup'
  item 8 'System Utilities (BBR / Netflix)'
  item 9 'Advanced Settings (domain / obfuscation)'
  item 10 'Reboot Server'
  item 11 'Hysteria 2 Account Management (UDP)'
  item 12 'OpenVPN Account Management (OpenVPN3)'
  item 13 'WireGuard Account Management (UDP)'
  printf '  [%b00%b] %bExit%b\n' "$RED" "$NC" "$BOLD" "$NC"
  echo
  read -r -p '  ► Select an option: ' choice
  case "$choice" in
    1|01) ssh_menu ;;
    2|02) xray_menu ;;
    3|03) hysteria1_menu ;;
    4|04) zivpn_menu ;;
    5|05) bash "$script_dir/maintenance-v6.sh" monitor; pause ;;
    6|06) maintenance_menu ;;
    7|07) bash "$script_dir/maintenance-v6.sh" backup; pause ;;
    8|08) utilities_menu ;;
    9|09) settings_menu ;;
    10) read -r -p 'Reboot server now? [y/N] ' confirm; [[ "$confirm" =~ ^[Yy]$ ]] && reboot ;;
    11) hysteria2_menu ;;
    12) openvpn_menu ;;
    13) wireguard_menu ;;
    0|00) exit 0 ;;
    *) echo 'Invalid option.'; sleep 1 ;;
  esac
done
