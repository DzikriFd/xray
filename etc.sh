#!/usr/bin/env bash
# etc.sh - library + CLI subcommand
# Pemakaian:
#   sudo /usr/local/sbin/etc.sh clear-cache
#   sudo /usr/local/sbin/etc.sh clear-log
#   sudo /usr/local/sbin/etc.sh auto-reboot
#   sudo /usr/local/sbin/etc.sh monitor

set -euo pipefail

# =========[ KONFIGURASI ]=========
IFACES=("eth0" "eth1")
REB_SVC="auto-reboot.service"
REB_TMR="auto-reboot.timer"
REB_SVC_PATH="/etc/systemd/system/$REB_SVC"
REB_TMR_PATH="/etc/systemd/system/$REB_TMR"
REB_LOG="/var/log/auto-reboot.log"
QUOTA_CONF="/etc/bandwidth_quota.conf"
VNSTAT_BIN="$(command -v vnstat || true)"

line_etc(){ echo "==========================="; }

# =========[ UTIL ]=========
need_root() { [[ $EUID -eq 0 ]] || { echo "Jalankan sebagai root: sudo $0 ..."; exit 1; }; }
press_enter() { read -rp "Tekan ENTER untuk lanjut... " _ || true; }
ensure_systemd_reload() { systemctl daemon-reload; }
filter_existing_ifaces() { for i in "${IFACES[@]}"; do ip link show "$i" &>/dev/null && echo "$i"; done; }
ensure_vnstat() {
  if [[ -z "$VNSTAT_BIN" ]]; then
    apt-get update -y && apt-get install -y vnstat
    VNSTAT_BIN="$(command -v vnstat || true)"
    [[ -z "$VNSTAT_BIN" ]] && { echo "vnstat gagal diinstal."; return 1; }
    systemctl enable --now vnstat || true
  fi
  while read -r i; do [[ -n "$i" ]] && vnstat --add -i "$i" >/dev/null 2>&1 || true; done < <(filter_existing_ifaces)
  return 0
}

# =========[ FUNGSI YANG DIMINTA ]=========
clear_cache() {
  need_root
  line_etc
  echo "     MEMBERSIHKAN CACHE     "
  line_etc
  du -sh /var/cache 2>/dev/null || true
  sync; echo 3 > /proc/sys/vm/drop_caches || true
  apt-get clean -y >/dev/null 2>&1 || true
  rm -rf /var/cache/apt/archives/partial 2>/dev/null || true
  find /home -maxdepth 3 -type d -name ".cache" -prune -exec rm -rf {} + 2>/dev/null || true
  rm -rf /root/.cache 2>/dev/null || true
  du -sh /var/cache 2>/dev/null || true
  echo "Selesai."
}

clear_log() {
  need_root
  line_etc
  echo "    MEMBERSIHKAN LOG    "
  line_etc
  command -v journalctl >/dev/null && journalctl --vacuum-size=100M || true
  find /var/log -type f \( -name "*.gz" -o -name "*.1" -o -name "*.old" -o -name "*.xz" \) -delete 2>/dev/null || true
  while IFS= read -r -d '' f; do : > "$f" || true; done < <(find /var/log -type f -size +50M -print0 2>/dev/null)
  echo "Selesai."
}

ensure_reboot_unit() {
  cat > "$REB_SVC_PATH" <<'SERVICE'
[Unit]
Description=Auto Reboot (terjadwal)

[Service]
Type=oneshot
# DRY_RUN=1 untuk test tanpa benar-benar reboot
Environment=DRY_RUN=0

# Tulis log sebelum reboot (PERHATIKAN: %% untuk escape %)
ExecStartPre=/bin/sh -lc 'echo "[AUTO-REBOOT] $(date +%%F_%%T)" >> /var/log/auto-reboot.log || true'

# Reboot dengan beberapa fallback path; kalau DRY_RUN=1, exit 0
ExecStart=/bin/sh -lc '[ "$DRY_RUN" = "1" ] && { echo "DRY RUN: skip reboot" >> /var/log/auto-reboot.log; exit 0; }; \
  /usr/sbin/shutdown -r now || /sbin/shutdown -r now || \
  /usr/sbin/reboot -f || /sbin/reboot -f || \
  /bin/systemctl --no-wall reboot'

TimeoutStartSec=30
SERVICE
  chmod 0644 "$REB_SVC_PATH"
}

write_timer_every() {
  local interval="$1"
  cat > "$REB_TMR_PATH" <<TIMER
[Unit]
Description=Timer untuk auto-reboot setiap $interval

[Timer]
OnUnitActiveSec=$interval
AccuracySec=1min
# Persistent=false (default) mencegah "catch-up" langsung
Unit=$REB_SVC

[Install]
WantedBy=timers.target
TIMER
  chmod 0644 "$REB_TMR_PATH"
}

write_timer_daily() {
  cat > "$REB_TMR_PATH" <<'TIMER'
[Unit]
Description=Timer untuk auto-reboot harian pukul 03:00

[Timer]
OnCalendar=*-*-* 03:00:00
AccuracySec=1min
Unit=auto-reboot.service

[Install]
WantedBy=timers.target
TIMER
  chmod 0644 "$REB_TMR_PATH"
}

enable_timer() {
  ensure_systemd_reload

  # enable + start timer
  if systemctl enable --now "$REB_TMR"; then
    # verifikasi cepat (opsional)
    is_enabled="$(systemctl is-enabled "$REB_TMR" 2>/dev/null || true)"
    is_active="$(systemctl is-active "$REB_TMR" 2>/dev/null || true)"

    if [[ "$is_enabled" == "enabled" && "$is_active" == "active" ]]; then
      echo "✅ Auto reboot berhasil di setting."
    else
      echo "⚠️  Auto reboot dicoba diaktifkan, namun status: enabled=$is_enabled active=$is_active"
      echo "    Cek: systemctl status --no-pager $REB_TMR"
    fi
  else
    echo "❌ Gagal mengaktifkan auto reboot timer: $REB_TMR"
  fi

  # tampilkan sedikit info & tunggu ENTER
  systemctl status --no-pager "$REB_TMR" || true
  read -rp "Tekan ENTER untuk kembali..." _ || true
}
# Hapus auto set reboot sepenuhnya (tetap sama)
remove_auto_reboot() {
  echo "Menonaktifkan dan menghapus unit auto-reboot..."
  systemctl stop "$REB_TMR" 2>/dev/null || true
  systemctl disable "$REB_TMR" 2>/dev/null || true
  rm -f "$REB_TMR_PATH" "$REB_SVC_PATH"
  ensure_systemd_reload
  echo "Auto set reboot dihapus."
}

auto_set_reboot() {
  need_root
  while :; do
    clear
    line_etc
    echo "      AUTO SET REBOOT      "
    line_etc
    echo "1) Reboot setiap 1 jam"
    echo "2) Reboot setiap 6 jam"
    echo "3) Reboot setiap 12 jam"
    echo "4) Reboot setiap 1 hari (03:00)"
    echo "5) Delete reboot log ($REB_LOG)"
    echo "6) Hapus auto set reboot (disable & hapus unit)"
    echo "0) Batal"
    line_etc
    read -rp "Pilih [0-6]: " opt || true

    case "${opt:-}" in
      1) ensure_reboot_unit; write_timer_every "1h";  enable_timer;   return 0 ;;
      2) ensure_reboot_unit; write_timer_every "6h";  enable_timer;   return 0 ;;
      3) ensure_reboot_unit; write_timer_every "12h"; enable_timer;   return 0 ;;
      4) ensure_reboot_unit; write_timer_daily;       enable_timer;   return 0 ;;
      5) rm -f "$REB_LOG"; echo "Log dihapus."; read -rp "Tekan ENTER untuk kembali..." _ || true; return 0 ;;
      6) remove_auto_reboot; read -rp "Tekan ENTER untuk kembali..." _ || true; return 0 ;;
      0|'') echo "Dibatalkan."; return 0 ;;
      *) echo "Pilihan tidak dikenal."; sleep 1 ;;
    esac
  done
}

month_usage_gib_one() {
  local IFACE="$1" used="0"
  if command -v jq >/dev/null 2>&1; then
    local JSON; JSON="$(vnstat --json m -i "$IFACE" 2>/dev/null || true)"
    used="$(echo "$JSON" | jq -r '
      .interfaces[]?|select(.name=="'"$IFACE"'")|.traffic.months[]?
      |select(.date.year==(now|gmtime.year+1900) and .date.month==(now|gmtime.month+1))
      |(.rx+.tx)/(1024*1024*1024)
    ' 2>/dev/null | awk '{s+=$1} END{printf("%.3f", s+0)}')"
    [[ -z "$used" ]] && used="0"
  else
    used="$(vnstat -m -i "$IFACE" 2>/dev/null | awk '
      BEGIN{m=strftime("%b")}
      $1==m {for(i=1;i<=NF;i++){ if($(i) ~ /GiB|MiB|TiB/){v=$(i-1);u=$(i);
        g=v; if(u=="MiB") g=v/1024; if(u=="TiB") g=v*1024; sum+=g }}
      END{printf("%.3f", sum+0)}')"
    [[ -z "$used" ]] && used="0"
  fi
  printf "%s" "$used"
}

bw_quota_remaining() {
  ensure_vnstat || return 1
  mapfile -t LIST < <(filter_existing_ifaces)
  ((${#LIST[@]})) || { echo "eth0/eth1 tidak ditemukan."; return 0; }

  if [[ ! -s "$QUOTA_CONF" ]]; then
    read -rp "Masukkan TOTAL_GB kuota bulanan (contoh 500): " TOT || true
    echo "TOTAL_GB=${TOT:-0}" > "$QUOTA_CONF"
  fi
  # shellcheck disable=SC1090
  source "$QUOTA_CONF"
  local TOTAL="${TOTAL_GB:-0}" sum="0" used
  echo "Pemakaian bulan berjalan:"
  for i in "${LIST[@]}"; do
    used="$(month_usage_gib_one "$i")"
    printf "  - %-5s: %s GiB\n" "$i" "$used"
    sum=$(awk -v a="$sum" -v b="$used" 'BEGIN{printf("%.3f", a+b)}')
  done
  local remaining; remaining=$(awk -v t="$TOTAL" -v u="$sum" 'BEGIN{r=t-u; if(r<0) r=0; printf("%.3f", r)}')
  echo "TOTAL KUOTA : ${TOTAL} GiB"
  echo "TERPAKAI    : ${sum} GiB"
  echo "SISA        : ${remaining} GiB"
}

bw_table_5min()    { ensure_vnstat || return 1; for i in $(filter_existing_ifaces); do echo "---- $i (5 menit) ----"; vnstat -5 -i "$i" 2>/dev/null || vnstat -h -i "$i"; echo; done; }
bw_table_hourly()  { ensure_vnstat || return 1; for i in $(filter_existing_ifaces); do echo "---- $i (hourly) ----";  vnstat -h -i "$i"; echo; done; }
bw_table_daily()   { ensure_vnstat || return 1; for i in $(filter_existing_ifaces); do echo "---- $i (daily) ----";   vnstat -d -i "$i"; echo; done; }
bw_table_monthly() { ensure_vnstat || return 1; for i in $(filter_existing_ifaces); do echo "---- $i (monthly) ----"; vnstat -m -i "$i"; echo; done; }
bw_live_5s()       { ensure_vnstat || return 1; for i in $(filter_existing_ifaces); do echo "---- $i (live 5s) ----"; vnstat -tr 5 -i "$i"; echo; done; }

monitor_bandwith() {
  while :; do
    clear
    line_etc
    echo "    MONITOR BANDWITH    "
    line_etc
    echo "1) Total bandwidth tersisa"
    echo "2) Tabel 5 menit"
    echo "3) Tabel per jam"
    echo "4) Tabel per hari"
    echo "5) Tabel per bulan"
    echo "6) Trafik aktif 5 detik"
    echo "0) Kembali"
    line_etc
    read -rp "Pilih [0-6]: " o || true

    case "${o:-}" in
      1) bw_quota_remaining;  read -rp "Tekan ENTER untuk kembali..." _ || true ;;
      2) bw_table_5min;       read -rp "Tekan ENTER untuk kembali..." _ || true ;;
      3) bw_table_hourly;     read -rp "Tekan ENTER untuk kembali..." _ || true ;;
      4) bw_table_daily;      read -rp "Tekan ENTER untuk kembali..." _ || true ;;
      5) bw_table_monthly;    read -rp "Tekan ENTER untuk kembali..." _ || true ;;
      6) bw_live_5s;          read -rp "Tekan ENTER untuk kembali..." _ || true ;;
      0|'') echo "Kembali."; return 0 ;;
      *) echo "Pilihan tidak dikenal."; sleep 1 ;;
    esac
  done
}

# =========[ DISPATCHER: hanya jalan kalau ada argumen ]=========
case "${1:-}" in
  clear-cache|clear_cache|1)       clear_cache ;;
  clear-log|clear_log|2)           clear_log ;;
  auto-reboot|auto_set_reboot|3)   auto_set_reboot ;;
  monitor|monitor-bw|monitor_bandwith|4) monitor_bandwith ;;
  "" ) # tidak melakukan apa-apa agar aman dipanggil tanpa argumen
       ;;
  * )  echo "Usage: $0 {clear-cache|clear-log|auto-reboot|monitor}"; exit 1 ;;
esac
