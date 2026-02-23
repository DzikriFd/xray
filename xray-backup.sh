#!/usr/bin/env bash

# ====== MODE DETEKSI (CLI vs LIB) ======
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  # dieksekusi langsung -> CLI mode
  set -euo pipefail
  __XRAY_BACKUP_MODE="cli"
else
  # di-source dari script lain -> LIB mode
  __XRAY_BACKUP_MODE="lib"
fi

# ====== AUTO-DETEKSI PATH DIRI ======
SELF="$(readlink -f "${BASH_SOURCE[0]}")"

# ====== KONFIG DASAR ======
RCLONE_REMOTE="${RCLONE_REMOTE:-gdrive}"
GDRIVE_DIR="${GDRIVE_DIR:-xray-backups}"
BACKUP_DIR="${BACKUP_DIR:-/usr/local/etc/xray/backup}"
CONF_FILE="${CONF_FILE:-/usr/local/etc/xray/backup.conf}"

TARGETS=(/usr/local/etc/xray /etc/vless /etc/vmess /etc/trojan /etc/shadowsocks)

log()   { printf '[%s] %s\n' "$(date '+%F %T')" "$*"; }
die()   { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
need_cmd(){ command -v "$1" >/dev/null 2>&1 || die "Perlu perintah: $1 (install dahulu)"; }

ensure_deps_tg(){ for c in zip unzip curl; do need_cmd "$c"; done; }

send_telegram(){
  local file="$1" cap="${2:-}"
  load_conf
  if [[ -z "${TELEGRAM_TOKEN:-}" || -z "${TELEGRAM_CHAT_ID:-}" ]]; then
    log "TOKEN/CHAT_ID Telegram belum tersedia; lewati pengiriman."
    return 1
  fi
  curl -fsS -X POST \
    -F "chat_id=${TELEGRAM_CHAT_ID}" \
    -F "caption=${cap}" \
    -F "document=@${file}" \
    "https://api.telegram.org/bot${TELEGRAM_TOKEN}/sendDocument" >/dev/null
}

ensure_deps(){ for c in rclone zip unzip curl; do need_cmd "$c"; done; }
ensure_dirs(){ sudo mkdir -p "$BACKUP_DIR" "$(dirname "$CONF_FILE")" || true; }
load_conf(){ [[ -f "$CONF_FILE" ]] && source "$CONF_FILE"; }
save_conf_kv(){ local k="$1" v="$2"; sudo touch "$CONF_FILE"; sudo chmod 600 "$CONF_FILE"
  if grep -qE "^${k}=" "$CONF_FILE" 2>/dev/null; then
    sudo sed -i "s|^${k}=.*|${k}=\"${v//|/\\|}\"|g" "$CONF_FILE"
  else echo "${k}=\"${v}\"" | sudo tee -a "$CONF_FILE" >/dev/null; fi; }
first_run_checks(){ load_conf; if [[ -z "${GMAIL_EMAIL:-}" ]]; then
  read -rp "Masukkan email Gmail untuk backup: " GMAIL_EMAIL
  [[ -z "$GMAIL_EMAIL" ]] && die "Email tidak boleh kosong."; save_conf_kv GMAIL_EMAIL "$GMAIL_EMAIL"; fi; }

get_public_ip(){ local ip=""; ip=$(curl -fsS https://api.ipify.org || true)
  [[ -z "$ip" ]] && ip=$(curl -fsS https://ifconfig.me || true)
  [[ -z "$ip" ]] && ip=$(hostname -I 2>/dev/null | awk '{print $1}' || true)
  [[ -z "$ip" ]] && ip="unknown-ip"; echo "$ip"; }
timestamp(){ date '+%Y%m%d-%H%M%S'; }

extract_gdrive_id(){ local url="$1" id=""
  if [[ "$url" =~ /file/d/([^/]+)/? ]]; then id="${BASH_REMATCH[1]}";
  elif [[ "$url" =~ id=([^&]+) ]]; then id="${BASH_REMATCH[1]}";
  elif [[ "$url" =~ /folders/([^/?]+) ]]; then id="${BASH_REMATCH[1]}"; fi
  echo "$id"; }

do_backup(){
  ensure_deps; ensure_dirs; first_run_checks
  [[ -z "$(rclone listremotes 2>/dev/null | grep -E "^${RCLONE_REMOTE}:$")" ]] \
    && log "Peringatan: remote rclone '${RCLONE_REMOTE}:' belum terdeteksi. Jalankan 'rclone config' bila perlu."
  local ip fname tmpfile; ip="$(get_public_ip)"; fname="${ip}_$(timestamp).zip"
  tmpfile="${BACKUP_DIR}/${fname}"
  log "Membuat arsip: $tmpfile"
  local list=(); for d in "${TARGETS[@]}"; do [[ -d "$d" ]] && list+=("$d"); done
  [[ "${#list[@]}" -eq 0 ]] && die "Tidak ada folder target ditemukan."
  (cd / && sudo zip -r -q "$tmpfile" "${list[@]/#/./}") || die "Gagal membuat ZIP"
  local drive_path="${RCLONE_REMOTE}:${GDRIVE_DIR}/${ip}/"
  log "Upload ke Google Drive: ${drive_path}"
  rclone mkdir "${drive_path}" >/dev/null 2>&1 || true
  rclone copy -P "$tmpfile" "${drive_path}" || die "Upload ke Google Drive gagal."
  load_conf
  if [[ -n "${TELEGRAM_TOKEN:-}" && -n "${TELEGRAM_CHAT_ID:-}" ]]; then
    log "Kirim ke Telegram chat_id=${TELEGRAM_CHAT_ID}"
    curl -fsS -X POST \
      -F "chat_id=${TELEGRAM_CHAT_ID}" \
      -F "caption=Backup ${ip} @ $(date '+%F %T')" \
      -F "document=@${tmpfile}" \
      "https://api.telegram.org/bot${TELEGRAM_TOKEN}/sendDocument" >/dev/null || log "Gagal kirim Telegram."
  else
    log "TOKEN/CHAT_ID Telegram belum di-set. Lewati pengiriman Telegram."
  fi
  log "Selesai. File: $tmpfile"
}

do_restore(){
  ensure_deps
  local src="${1:-}" work="/tmp/xray-restore-$(timestamp)"; mkdir -p "$work"
  if [[ -z "$src" ]]; then read -rp "Masukkan LINK Google Drive atau path .zip lokal: " src; [[ -z "$src" ]] && die "Sumber restore wajib."; fi
  local zipfile=""
  if [[ "$src" =~ ^https?:// ]]; then
    local fid; fid="$(extract_gdrive_id "$src")"; [[ -z "$fid" ]] && die "Gagal ekstrak File ID."
    log "Mengunduh dari Google Drive (id=$fid)"; rclone copy -P "${RCLONE_REMOTE}:${fid}" "$work" || die "Unduh gagal."
    zipfile="$(find "$work" -maxdepth 1 -type f -name '*.zip' | head -n1)"; [[ -z "$zipfile" ]] && die "ZIP tidak ditemukan."
  else [[ -f "$src" ]] || die "File tidak ditemukan: $src"; zipfile="$src"; fi
  log "Akan restore ke /. Ketik 'YES' untuk lanjut."
  read -rp "Konfirmasi: " ans; [[ "$ans" == "YES" ]] || die "Restore dibatalkan."
  sudo unzip -o -q "$zipfile" -d / || die "Ekstrak gagal."
  log "Restore selesai. Pertimbangkan: sudo systemctl restart xray"
}
do_backup_telegram_only(){
  ensure_deps_tg; ensure_dirs
  # pastikan kredensial TG
  load_conf
  if [[ -z "${TELEGRAM_TOKEN:-}" ]]; then
    read -rp "Masukkan Telegram BOT TOKEN: " TELEGRAM_TOKEN
    [[ -z "$TELEGRAM_TOKEN" ]] && die "TOKEN wajib."
    save_conf_kv TELEGRAM_TOKEN "$TELEGRAM_TOKEN"
  fi
  if [[ -z "${TELEGRAM_CHAT_ID:-}" ]]; then
    read -rp "Masukkan Telegram CHAT_ID: " TELEGRAM_CHAT_ID
    [[ -z "$TELEGRAM_CHAT_ID" ]] && die "CHAT_ID wajib."
    save_conf_kv TELEGRAM_CHAT_ID "$TELEGRAM_CHAT_ID"
  fi

  local ip fname tmpfile
  ip="$(get_public_ip)"
  fname="${ip}_$(timestamp).zip"
  tmpfile="${BACKUP_DIR}/${fname}"

  log "Membuat arsip (Telegram-only): $tmpfile"
  local list=(); for d in "${TARGETS[@]}"; do [[ -d "$d" ]] && list+=("$d"); done
  [[ "${#list[@]}" -eq 0 ]] && die "Tidak ada folder target yang ditemukan."
  (cd / && sudo zip -r -q "$tmpfile" "${list[@]/#/./}") || die "Gagal membuat ZIP"

  log "Mengirim ke Telegram..."
  if send_telegram "$tmpfile" "Backup ${ip} @ $(date '+%F %T') (Telegram-only)"; then
    log "Kirim Telegram sukses."
  else
    die "Kirim Telegram gagal."
  fi
  log "Selesai (Telegram-only). File lokal: $tmpfile"
}

setup_auto_backup(){
  ensure_deps_tg; ensure_dirs; load_conf

  # Minta TOKEN & CHAT_ID (khusus Telegram-only)
  if [[ -z "${TELEGRAM_TOKEN:-}" ]]; then
    read -rp "Masukkan Telegram BOT TOKEN: " TELEGRAM_TOKEN
    [[ -z "$TELEGRAM_TOKEN" ]] && die "TOKEN wajib."
    save_conf_kv TELEGRAM_TOKEN "$TELEGRAM_TOKEN"
  fi
  if [[ -z "${TELEGRAM_CHAT_ID:-}" ]]; then
    read -rp "Masukkan Telegram CHAT_ID: " TELEGRAM_CHAT_ID
    [[ -z "$TELEGRAM_CHAT_ID" ]] && die "CHAT_ID wajib."
    save_conf_kv TELEGRAM_CHAT_ID "$TELEGRAM_CHAT_ID"
  fi

  # Unit systemd pakai subcommand backup-tg
  local svc=/etc/systemd/system/xray-autobackup.service
  local tmr=/etc/systemd/system/xray-autobackup.timer

  sudo tee "$svc" >/dev/null <<UNIT
[Unit]
Description=Auto backup Xray (Telegram-only)

[Service]
Type=oneshot
ExecStart=${SELF} backup-tg
UNIT

  sudo tee "$tmr" >/dev/null <<'UNIT'
[Unit]
Description=Run xray-autobackup daily at 23:59 (Telegram-only)

[Timer]
OnCalendar=*-*-* 23:59:00
Persistent=true
Unit=xray-autobackup.service

[Install]
WantedBy=timers.target
UNIT

  sudo systemctl daemon-reload
  sudo systemctl enable --now xray-autobackup.timer
  log "Auto-backup (Telegram-only) aktif tiap 23:59."

  # Jalankan backup SEKARANG juga (Telegram-only) tanpa mengubah jadwal
  log "Menjalankan backup (Telegram-only) pertama sekarang..."
  if do_backup_telegram_only; then
    log "Backup langsung (Telegram-only) sukses."
    read -rp "Selesai. Tekan ENTER untuk kembali..." _
    return 0
  else
    log "Backup langsung (Telegram-only) gagal, timer tetap aktif."
    read -rp "Selesai. Tekan ENTER untuk kembali..." _
    return 0
  fi
}

clear_backups(){
  ensure_dirs
  local mode="${1:-all}"

  # Hanya dukung mode "all"
  if [[ "$mode" != "all" ]]; then
    echo "Mode tidak didukung. Gunakan: clear all"
    read -rp "Tekan ENTER untuk kembali..." _
    return 0
  fi

  read -rp "Hapus SEMUA file Backup ketik 'YES': " ans
  if [[ "$ans" != "YES" ]]; then
    echo "Dibatalkan."
    read -rp "Tekan ENTER untuk kembali..." _
    return 0
  fi

  sudo find "$BACKUP_DIR" -type f -name '*.zip' -print -delete
  log "Semua file backup dihapus."
  read -rp "Selesai. Tekan ENTER untuk kembali..." _
  return 0
}

usage(){ cat <<EOF
  backup-tg              Buat backup ZIP -> kirim Telegram saja (tanpa Google Drive)
Pemakaian: $(basename "$0") <perintah> [opsi]
  backup                 Buat backup ZIP -> Drive -> Telegram (jika token/chat_id ada)
  restore [SRC]          Restore dari link Google Drive atau path .zip lokal
  auto-setup             Jadwalkan auto-backup 23:59 via systemd
  clear [all|older] [N]  Bersihkan backup: 'all' hapus semua, 'older' >N hari (default 14)

Config: $CONF_FILE
EOF
}

main(){
  local cmd="${1:-}"; shift || true
  case "${cmd:-}" in
    backup)       do_backup "$@";;
    restore)      do_restore "${1:-}";;
    backup-tg)    do_backup_telegram_only "$@";;
    auto-setup)   setup_auto_backup;;
    clear)        clear_backups "${1:-older}" "${2:-}";;
    ""|-h|--help) usage;;
    *)            usage; exit 1;;
  esac
}

# Hanya jalankan main saat CLI mode; saat LIB mode (disource) cukup ekspor fungsinya
if [[ "${__XRAY_BACKUP_MODE:-cli}" == "cli" ]]; then
  main "$@"
fi


