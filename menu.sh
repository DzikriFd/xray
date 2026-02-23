#!/bin/bash

# =================================================================
# SKRIP KERANGKA (SKELETON) MANAJEMEN SERVER VPN XRAY
# 
# PERINGATAN: 
# Ini HANYA kerangka menu (UI). Tidak ada logika backend.
# Anda perlu mengimplementasikan setiap fungsi (ditandai [TODO]).
# 
# Untuk fungsi VMESS/VLESS/TROJAN, Anda perlu:
# 1. Menginstal Xray API client (e.g., v2ray-api, xray-api)
# 2. Memastikan Xray 'api' service aktif di config.json
# 3. Menulis fungsi bash untuk memanggil API tsb.
#
# Untuk fungsi SSH, Anda perlu:
# 1. Logika 'useradd', 'userdel', 'passwd', 'chage'
# 2. Skrip untuk memantau 'ps' atau 'last'
# 3. Database flat-file (e.g., /root/users.db) untuk menyimpan tgl kadaluarsa
# =================================================================
set -eu
source vless.sh
source vmess.sh
source trojan.sh
source xray-backup.sh
source etc.sh

# Colors
red=$(printf '\033[31m'); green=$(printf '\033[32m'); yellow=$(printf '\033[33m'); blue=$(printf '\033[34m'); magenta=$(printf '\033[35m'); cyan=$(printf '\033[36m'); reset=$(printf '\033[0m')
bold=$(printf '\033[1m')

require_root() {
  if [[ $EUID -ne 0 ]]; then
    echo "Jalankan sebagai root." ; exit 1
  fi
}

cmd_exists(){ command -v "$1" >/dev/null 2>&1; }

get_ip() {
  # fallback tanpa internet khusus, gunakan ip route
  ip -4 addr show scope global | awk '/inet /{print $2}' | cut -d/ -f1 | head -n1
}

pause(){ read -rp "Enter untuk lanjut..."; }

# --- Fungsi TODO (Placeholder) ---
# Ganti 'echo' di bawah ini dengan perintah Anda yang sebenarnya.

# SSH
fn_create_ssh() { clear; echo "Menjalankan: Buat Akun SSH..."; echo "[TODO] Implementasikan logika useradd, passwd, chage."; sleep 2; }
fn_trial_ssh() { clear; echo "Menjalankan: Buat Akun Trial SSH (misal 1 jam)..."; echo "[TODO] Implementasikan useradd + at job untuk userdel."; sleep 2; }
fn_delete_ssh() { clear; echo "Menjalankan: Hapus Akun SSH..."; echo "[TODO] Implementasikan logika userdel."; sleep 2; }
fn_renew_ssh() { clear; echo "Menjalankan: Perpanjang Akun SSH..."; echo "[TODO] Implementasikan logika chage -E."; sleep 2; }
fn_cek_ssh_ws() { clear; echo "Menjalankan: Cek User Login SSH-WS..."; echo "[TODO] Implementasikan logika cek koneksi (misal: netstat, lsof)."; sleep 2; }
fn_cek_ssh_udp() { clear; echo "Menjalankan: Cek User Login UDP (e.g., BadVPN)..."; echo "[TODO] Implementasikan logika cek."; sleep 2; }
fn_cek_multi_ssh() { clear; echo "Menjalankan: Cek User Multi Login SSH..."; echo "[TODO] Implementasikan logika monitoring (ps, netstat)."; sleep 2; }
fn_auto_del_exp() { clear; echo "Menjalankan: Setup Cron Auto Delete Expired Users..."; echo "[TODO] Implementasikan pembuatan cron job."; sleep 2; }
fn_auto_kill_ssh() { clear; echo "Menjalankan: Setup Cron Auto Kill Multi Login..."; echo "[TODO] Implementasikan pembuatan cron job."; sleep 2; }
fn_list_ssh() { clear; echo "Menjalankan: Cek Semua Member SSH..."; echo "[TODO] Implementasikan pembacaan database user Anda."; sleep 2; }
fn_tendang_ssh() { clear; echo "Menjalankan: Tendang User Multi Login..."; echo "[TODO] Implementasikan logika kill PID."; sleep 2; }

# XRAY (VMESS/VLESS/TROJAN) - Ini membutuhkan Xray API
fn_create_xray() { local proto=$1; clear; echo "Menjalankan: Buat Akun $proto..."; echo "[TODO] Panggil Xray API: AddUser"; sleep 2; }
fn_trial_xray() { local proto=$1; clear; echo "Menjalankan: Buat Akun Trial $proto..."; echo "[TODO] Panggil Xray API: AddUser + at job untuk RemoveUser"; sleep 2; }
fn_delete_xray() { local proto=$1; clear; echo "Menjalankan: Hapus Akun $proto..."; echo "[TODO] Panggil Xray API: RemoveUser"; sleep 2; }
fn_renew_xray() { local proto=$1; clear; echo "Menjalankan: Perpanjang Akun $proto..."; echo "[TODO] Implementasikan logika (Xray API tidak punya 'renew', jadi Anda perlu logic DB sendiri)"; sleep 2; }
fn_cek_xray() { local proto=$1; clear; echo "Menjalankan: Cek User Login $proto..."; echo "[TODO] Panggil Xray API: StatsService (QueryStats)"; sleep 2; }

# LAIN-LAIN
fn_change_domain() { 
    clear
    echo "Fungsi Ganti Domain"
    read -p "Masukkan domain baru: " NEW_DOMAIN
    echo "[TODO] Implementasikan logika: "
    echo "1. Hentikan nginx"
    echo "2. Jalankan certbot untuk $NEW_DOMAIN"
    echo "3. Update config Nginx dengan domain baru"
    echo "4. Update config Xray (jika perlu)"
    echo "5. Simpan domain baru di /root/domain.txt"
    echo "6. Restart nginx & xray"
    sleep 4
}

# LAIN-LAIN
fn_change_domain() { 
    clear
    echo "Fungsi Ganti Domain"
    read -p "Masukkan domain baru: " NEW_DOMAIN
    echo "[TODO] Implementasikan logika: "
    echo "1. Hentikan nginx"
    echo "2. Jalankan certbot untuk $NEW_DOMAIN"
    echo "3. Update config Nginx dengan domain baru"
    echo "4. Update config Xray (jika perlu)"
    echo "5. Simpan domain baru di /root/domain.txt"
    echo "6. Restart nginx & xray"
    sleep 4
}
fn_gotop_ram() { clear; echo "--- Menjalankan Gotop (Keluar: q) ---"; sleep 1; gotop; clear; echo "--- Menampilkan RAM ---"; free -h; sleep 3; }
fn_speedtest() { clear; echo "--- Menjalankan Speedtest ---"; speedtest-cli; sleep 5; }
fn_restart_vps() { clear; read -p "Anda yakin ingin REBOOT VPS? (y/n): " confirm && [[ $confirm == [yY] ]] && (echo "REBOOTING..."; sudo reboot); }
fn_restart_services() { 
    clear
    echo "Merestart semua layanan terkait (Nginx, Xray, SSH)..."
    echo "[TODO] Implementasikan: systemctl restart xray nginx dropbear stunnel"
    systemctl restart xray
    systemctl restart nginx
    # systemctl restart dropbear
    # systemctl restart stunnel
    echo "Selesai."
    sleep 2
}

# --- Menu Bot Telegram ---
fn_bot_menu() {
    while true; do
        clear
        echo "=================================="
        echo "        SUBMENU BOT TELEGRAM      "
        echo "=================================="
        echo "[1] Create Bot Tele"
        echo "[2] Delete Bot Tele"
        echo "[3] Stop Bot Fanel"
        echo "[4] Restart Bot Fanel"
        echo "[5] Delete BOT notif"
        echo "[0] Back To Main Menu"
        echo "=================================="
        read -p "Pilih [0-5]: " opt
        case $opt in
            1) clear; echo "[TODO] Implementasi create bot"; sleep 2 ;;
            2) clear; echo "[TODO] Implementasi delete bot"; sleep 2 ;;
            3) clear; echo "[TODO] Implementasi stop bot"; sleep 2 ;;
            4) clear; echo "[TODO] Implementasi restart bot"; sleep 2 ;;
            5) clear; echo "[TODO] Implementasi delete bot notif"; sleep 2 ;;
            0) break ;;
            *) echo -e "${RED}Pilihan tidak valid!${NC}"; sleep 1 ;;
        esac
    done
}

# --- Menu Backup/Restore ---
fn_backup_menu() {
    while true; do
        clear
        echo "=================================="
        echo "      SUBMENU BACKUP & RESTORE    "
        echo "=================================="
        echo "[1] Backup Data"
        echo "[2] Restore Data"
        echo "[3] Auto Backup Data"
        echo "[4] Cleaner Data"
        echo "[0] Back To Main Menu"
        echo "=================================="
        read -p "Pilih [0-4]: " opt
        case $opt in
            1) do_backup ;;
            2) do_restore ;;
            3) setup_auto_backup ;;
            4) clear_backups ;;
            0) break ;;
            *) echo -e "${RED}Pilihan tidak valid!${NC}"; sleep 1 ;;
        esac
    done
}

# --- Menu Xray (Generik) ---
fn_xray_menu() {
  local proto=$1
  while true; do
    clear
    echo "=================================="
    echo "        SUBMENU $proto"
    echo "=================================="
    echo "[1] Create $proto Account"
    echo "[2] Trial  $proto Account"
    echo "[3] Delete $proto Account"
    echo "[4] Renew  $proto Account"
    echo "[5] Cek User Login $proto"
    echo "[6] Cek Config User $proto"
    echo "[0] Back To Main Menu"
    echo "=================================="
    read -p "Pilih [0-5]: " opt
    case $opt in
      1)
        case "$proto" in
          "VLESS") add_user_vless ;;
          "VMESS") add_user_vmess ;;
          "TROJAN") add_user_trojan ;;
        esac
        ;;
      2)
        case "$proto" in
          "VLESS") trial_user_vless ;;
          "VMESS") trial_user_vmess ;;
          "TROJAN") trial_user_trojan ;;
        esac
        ;;
      3)
        case "$proto" in
          "VLESS") delete_user_vless ;;
          "VMESS") delete_user_vmess ;;
          "TROJAN") delete_user_trojan ;;
        esac
        ;;
      4)
        case "$proto" in
          "VLESS") renew_user_vless ;;
          "VMESS") renew_user_vmess ;;
          "TROJAN") renew_user_trojan ;;
        esac
        ;;
      5)
        case "$proto" in
          "VLESS") show_login_user_vless ;;
          "VMESS") show_login_user_vmess ;;
          "TROJAN") show_login_user_trojan ;;
        esac
        ;;
      6)
        case "$proto" in
          "VLESS") show_config_vless ;;
          "VMESS") show_config_vmess ;;
          "TROJAN") show_config_trojan ;;
        esac
        ;;
      0) break ;;
      *) echo "Pilihan tidak valid!"; sleep 1 ;;
    esac
  done
}

# --- Menu SSH ---
fn_ssh_menu() {
    while true; do
        clear
        echo "=================================="
        echo "           SUBMENU SSH          "
        echo "=================================="
        echo "[1]  Create Ssh Account"
        echo "[2]  Trial Ssh Account"
        echo "[3]  Delete Ssh Account"
        echo "[4]  Perpanjang Ssh Account"
        echo "[5]  Cek User Login Ssh-Ws"
        echo "[6]  Cek User Login UDP"
        echo "[7]  Cek User Multi Log"
        echo "[8]  Auto Del User Exp"
        echo "[9]  Auto Kill User Ssh"
        echo "[10] Cek All Member Ssh"
        echo "[11] Tendang User Multi"
        echo "[0]  Back To Menu"
        echo "=================================="
        read -p "Pilih [0-11]: " opt
        case $opt in
            1) fn_create_ssh ;;
            2) fn_trial_ssh ;;
            3) fn_delete_ssh ;;
            4) fn_renew_ssh ;;
            5) fn_cek_ssh_ws ;;
            6) fn_cek_ssh_udp ;;
            7) fn_cek_multi_ssh ;;
            8) fn_auto_del_exp ;;
            9) fn_auto_kill_ssh ;;
            10) fn_list_ssh ;;
            11) fn_tendang_ssh ;;
            0) break ;;
            *) echo -e "${RED}Pilihan tidak valid!${NC}"; sleep 1 ;;
        esac
    done
}

# --- Menu Backup/Restore ---
# Pastikan sebelumnya ada:  . /usr/local/sbin/etc.sh

fn_etc() {
  while :; do
    clear
    echo "=================================="
    echo "         SUBMENU LAIN-LAIN        "
    echo "=================================="
    echo "[1] Clear Cache"
    echo "[2] Clear Log"
    echo "[3] Auto Set Reboot"
    echo "[4] Monitor Bandwith"
    echo "[0] Back To Main Menu"
    echo "=================================="
    read -rp "Pilih [0-4]: " opt

    case "${opt:-}" in
      1) clear; clear_cache;        read -rp "Tekan ENTER untuk kembali..." _ ;;
      2) clear; clear_log;          read -rp "Tekan ENTER untuk kembali..." _ ;;
      3) clear; auto_set_reboot ;;  # sudah ada loop & pause di dalamnya
      4) clear; monitor_bandwith ;; # sudah ada loop & pause di dalamnya
      0|'') break ;;
      *) echo "Pilihan tidak valid!"; sleep 1 ;;
    esac
  done
}

# ------------------ PANEL UI -----------------------------
SSH_CFG="/etc/xray.config.json"
XRAY_CFG="/etc/xray.config.json"
divider(){ printf "%s\n" "────────────────────────────────────────────────────────"; }

info_banner(){
  clear
  echo -e "${cyan}$(figlet -f small 'PANEL VPN')${reset}"
  echo
  echo -e "${bold}${magenta}Welcome To Script Premium All Os${reset}"
  divider
  . /etc/os-release
  IP=$(get_ip)
  UPT=$(awk '{printf "%d hours, %d minutes\n",$1/3600, ($1%3600)/60}' /proc/uptime)
  LOADCPU=$(grep 'cpu ' /proc/stat | awk '{u=$2+$4; t=$2+$4+$5} END {printf("%.0f", 100*u/t)}') || LOADCPU=0
  RAM_TOTAL=$(free -m | awk '/Mem:/ {print $2}')
  RAM_USED=$(free -m | awk '/Mem:/ {print $3}')
  DATE=$(date +%d-%m-%Y)
  TIME=$(date +%H-%M-%S)
  DOMAIN=$(cat domain.txt 2>/dev/null || echo "-")

  printf "${yellow}● SYSTEM OS      = ${reset}%s %s\n" "$NAME" "$VERSION"
  printf "${yellow}● SYSTEM CORE    = ${reset}%s\n" "$(nproc)"
  printf "${yellow}● SERVER RAM     = ${reset}%s / %s MB\n" "$RAM_TOTAL" "$RAM_USED"
  printf "${yellow}● LOADCPU        = ${reset}%s %%\n" "$LOADCPU"
  printf "${yellow}● DATE           = ${reset}%s\n" "$DATE"
  printf "${yellow}● TIME           = ${reset}%s\n" "$TIME"
  printf "${yellow}● UPTIME         = ${reset}%s\n" "$UPT"
  printf "${yellow}● IP VPS         = ${reset}%s\n" "$IP"
  printf "${yellow}● DOMAIN         = ${reset}%s\n" "$DOMAIN"
  echo
  echo -e "${bold}>>> INFORMATION ACCOUNT <<<${reset}"
  sshcount=$(jq '.inbounds[]|select(.tag=="vmess-ws")|.settings.clients|length' "$SSH_CFG" 2>/dev/null || echo 0)
  vmcount=$(jq '.inbounds[]|select(.tag=="vmess-ws")|.settings.clients|length' "$XRAY_CFG" 2>/dev/null || echo 0)
  vlcount=$(jq '.inbounds[]|select(.tag=="vless-ws")|.settings.clients|length' "$XRAY_CFG" 2>/dev/null || echo 0)
  trcount=$(jq '.inbounds[]|select(.tag=="trojan-ws")|.settings.clients|length' "$XRAY_CFG" 2>/dev/null || echo 0)
  printf "SSH/WS		= %s\n" "$vmcount"
  printf "VMESS/WS/GRPC   = %s\n" "$vmcount"
  printf "VLESS/WS/GRPC   = %s\n" "$vlcount"
  printf "TROJAN/WS/GRPC  = %s\n" "$trcount"
  echo
  echo -e "${bold}>>> WONG DEWEK <<<${reset}"
  printf "NGINX  %s   XRAY  %s\n" "$(systemctl is-active --quiet nginx && echo ON || echo OFF)" "$(systemctl is-active --quiet xray && echo ON || echo OFF)"
  divider
}
# --- MAIN MENU ---
fn_main_menu() {
    while true; do
        clear
        info_banner
        echo "============================================="
        echo "       MANAJEMEN SERVER VPN XRAY & SSH       "
        echo "============================================="
        echo "[1]  SSH MENU		[5]  BACKUP/RESTORE	[9]  BOT TELEGRAM"
        echo "[2]  VMESS MENU		[6]  CHANGE DOMAIN	[10] RESTART SERVICES"
        echo "[3]  VLESS MENU		[7]  GOTOP & RAM	[11] RESTART VPS"
        echo "[4]  TROJAN MENU	[8]  SPEEDTEST		[12] ETC"
        echo "============================================="
        read -p "Pilih [0-11]: " opt
        
        case $opt in
            1) fn_ssh_menu ;;
            2) fn_xray_menu "VMESS" ;;
            3) fn_xray_menu "VLESS" ;;
            4) fn_xray_menu "TROJAN" ;;
            5) fn_backup_menu ;;
            6) fn_change_domain ;;
            7) fn_gotop_ram ;;
            8) fn_speedtest ;;
            9) fn_bot_menu ;;
            10) fn_restart_services ;;
            11) fn_restart_vps ;;
            12) fn_etc ;;
            *) echo -e "${RED}Pilihan tidak valid!${NC}"; sleep 1 ;;
        esac
    done
}

# --- Jalankan Skrip ---
# Cek jika dijalankan sebagai root
if [ "$(id -u)" -ne 0 ]; then
  echo -e "${RED}Skrip ini harus dijalankan sebagai root!${NC}" >&2
  exit 1
fi

# Mulai menu utama
fn_main_menu
