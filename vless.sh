#!/usr/bin/env sh

# === KONFIG ===
XRAY_SERVICE="xray"
CFG="/usr/local/etc/xray/config.json"
VLESS_USERS_DIR="/usr/local/etc/xray/users/vless"
VLESS_LIMIT_DIR="/etc/vless/limit_ip"
BACKUP_DIR="/usr/local/etc/xray/backup"
ACCESS_LOG="/var/log/xray/access.log" # tidak wajib
DATE_FMT="%Y-%m-%d %H:%M:%S %Z"

# === UTIL ===
require_cmd() {
  for c in "$@"; do
    command -v "$c" >/dev/null 2>&1 || { echo "ERROR: butuh perintah '$c'"; exit 1; }
  done
}
require_root() { [ "$(id -u)" -eq 0 ] || { echo "Harus dijalankan sebagai root"; exit 1; }; }
ensure_layout() {
  require_cmd jq uuidgen date
  require_root
  [ -f "$CFG" ] || { echo "Config tidak ditemukan: $CFG"; exit 1; }
  mkdir -p "$VLESS_USERS_DIR" "$VLESS_LIMIT_DIR" "$BACKUP_DIR"
}

epoch_plus_days() { date -d "+$1 days" +%s; }
iso_from_epoch()  { date -u -d "@$1" +"%Y-%m-%dT%H:%M:%SZ"; }

user_exists() {
  jq -e --arg user "$1" '
    [ .inbounds[]? | select(.protocol=="vless")
      | (.settings.clients // [])[]?
      | select(.email==$user)
    ] | length > 0
  ' "$CFG" >/dev/null 2>&1
}

uuid_of_user() {
  jq -r --arg user "$1" '
    [ .inbounds[]? | select(.protocol=="vless")
      | (.settings.clients // [])[]?
      | select(.email==$user) | .id
    ][0] // empty
  ' "$CFG"
}

first_vless_inbound() {
  jq -r '(.inbounds[]? | select(.protocol=="vless")) | @base64' "$CFG" | head -n1
}
b64json() { printf "%s" "$1" | base64 -d; }

detect_host() {
  # urutan: XRAY_HOST env -> SNI/Reality serverName -> file domain -> IP publik -> IP lokal
  IN="$1"
  SNI=$(printf "%s" "$IN" | jq -r '.streamSettings.tlsSettings.serverName // .streamSettings.realitySettings.serverNames[0] // empty')
  if [ -n "${XRAY_HOST:-}" ]; then
    echo "$XRAY_HOST"; return
  elif [ -n "$SNI" ] && [ "$SNI" != "null" ]; then
    echo "$SNI"; return
  fi
  for f in /usr/local/etc/xray/domain /etc/xray/domain /etc/v2ray/domain; do
    [ -f "$f" ] && { tr -d '\r\n' < "$f"; echo; return; }
  done
  if command -v curl >/dev/null 2>&1; then
    PUB="$(curl -fsS --max-time 2 https://ifconfig.me || true)"
    [ -n "$PUB" ] && { echo "$PUB"; return; }
  fi
  hostname -I 2>/dev/null | awk '{print $1}' | tr -d ' ' || echo "127.0.0.1"
}

build_vless_uri() {
  USER="$1"; UUID="$2"
  B64="$(first_vless_inbound || true)"; [ -n "$B64" ] || { echo "# inbound VLESS tidak ditemukan di $CFG"; return; }
  J="$(b64json "$B64")"

  PORT="$(printf "%s" "$J" | jq -r '.port // "443"')"
  NET="$(printf "%s" "$J" | jq -r '.streamSettings.network // "tcp"')"
  SEC="$(printf "%s" "$J" | jq -r '.streamSettings.security // ""')"
  WSPATH="$(printf "%s" "$J" | jq -r '.streamSettings.wsSettings.path // ""')"
  WSHOST="$(printf "%s" "$J" | jq -r '.streamSettings.wsSettings.headers.Host // ""')"
  SNI="$(printf "%s" "$J" | jq -r '.streamSettings.tlsSettings.serverName // .streamSettings.realitySettings.serverNames[0] // ""')"
  GRPC_SVC="$(printf "%s" "$J" | jq -r '.streamSettings.grpcSettings.serviceName // ""')"
  REALITY_PBK="$(printf "%s" "$J" | jq -r '.streamSettings.realitySettings.publicKey // ""')"
  REALITY_SID="$(printf "%s" "$J" | jq -r '.streamSettings.realitySettings.shortId // ""')"

  HOST="$(detect_host "$J")"
  QP="type=$NET"
  if [ "$SEC" = "tls" ]; then
    QP="$QP&security=tls"
    [ -n "$SNI" ] && QP="$QP&sni=$SNI"
  elif [ "$SEC" = "reality" ]; then
    QP="$QP&security=reality"
    [ -n "$REALITY_PBK" ] && QP="$QP&pbk=$REALITY_PBK"
    [ -n "$REALITY_SID" ] && QP="$QP&sid=$REALITY_SID"
    [ -n "$SNI" ] && QP="$QP&sni=$SNI"
  fi
  case "$NET" in
    ws)
      [ -n "$WSPATH" ] && QP="$QP&path=$(printf "%s" "$WSPATH" | sed 's#^/#%2F#')"
      [ -n "$WSHOST" ] && QP="$QP&host=$WSHOST"
      ;;
    grpc)
      [ -n "$GRPC_SVC" ] && QP="$QP&serviceName=$GRPC_SVC&mode=gun"
      ;;
  esac

  echo "vless://${UUID}@${HOST}:${PORT}?${QP}#${USER}"
}

save_meta() {
  USER="$1"; UUID="$2"; EXP_EPOCH="$3"; DUR="$4"; MAXIP="$5"
  EXP_ISO="$(iso_from_epoch "$EXP_EPOCH")"
  mkdir -p "$VLESS_USERS_DIR" "$VLESS_LIMIT_DIR"
  cat > "$VLESS_USERS_DIR/$USER.json" <<EOF
{
  "username": "$USER",
  "uuid": "$UUID",
  "expire_epoch": $EXP_EPOCH,
  "expire_iso": "$EXP_ISO",
  "updated_at": "$(date +"$DATE_FMT")",
  "duration": "$DUR",
  "max_ip": $MAXIP
}
EOF
  echo "$MAXIP" > "$VLESS_LIMIT_DIR/$USER.limit"
}

reload_xray() {
  if systemctl reload "$XRAY_SERVICE" 2>/dev/null; then
    echo "Service $XRAY_SERVICE di-reload."
  else
    systemctl restart "$XRAY_SERVICE"
    echo "Service $XRAY_SERVICE di-restart."
  fi
}

# === FUNGSI: Tambah user VLESS (mode tanya) ===
add_user_vless() {
  ensure_layout

  # username
  while :; do
    printf "Username (x=Kembali): "
    IFS= read -r USERNAME || true
    case "${USERNAME:-}" in
      '' ) echo "Tidak boleh kosong."; continue ;;
      x|X) echo "Dibatalkan. Kembali ke menu."; printf "Tekan ENTER untuk kembali..."; IFS= read -r _ || true; return 0 ;;
    esac
    if user_exists "$USERNAME"; then
      echo "User '$USERNAME' sudah ada. Coba nama lain."
      continue
    fi
    break
  done

  # masa berlaku (hari)
  while :; do
    printf "Masa berlaku (hari) [default 30] (x=Kembali): "
    IFS= read -r DAYS || true
    case "${DAYS:-}" in
      '' ) DAYS="30" ;;
      x|X) echo "Dibatalkan. Kembali ke menu."; printf "Tekan ENTER untuk kembali..."; IFS= read -r _ || true; return 0 ;;
      *[!0-9]* ) echo "Harus angka bulat." ; continue ;;
    esac
    break
  done

  # limit IP
  while :; do
    printf "Maksimal IP [default 1] (x=Kembali): "
    IFS= read -r MAXIP || true
    case "${MAXIP:-}" in
      '' ) MAXIP="1" ;;
      x|X) echo "Dibatalkan. Kembali ke menu."; printf "Tekan ENTER untuk kembali..."; IFS= read -r _ || true; return 0 ;;
      *[!0-9]* ) echo "Harus angka bulat." ; continue ;;
    esac
    break
  done

  UUID="$(uuidgen)"
  EXP_EPOCH="$(epoch_plus_days "$DAYS")"
  EXP_ISO="$(iso_from_epoch "$EXP_EPOCH")"

  cp -f "$CFG" "$BACKUP_DIR/config.json.bak.$(date +%F-%H%M%S)"
  TMP="$(mktemp)"
  jq --arg user "$USERNAME" --arg uuid "$UUID" --arg exp "$EXP_ISO" '
    .inbounds |= (map(
      if .protocol=="vless" then
        .settings.clients = ((.settings.clients // []) + [{ "id": $uuid, "email": $user, "expiry": $exp }])
      else . end
    ))
  ' "$CFG" > "$TMP"
  mv "$TMP" "$CFG"

  save_meta "$USERNAME" "$UUID" "$EXP_EPOCH" "${DAYS}d" "$MAXIP"
  reload_xray

  LINK="$(build_vless_uri "$USERNAME" "$UUID")"
  echo ""
  echo "✅ VLESS user dibuat:"
  echo "  user     : $USERNAME"
  echo "  uuid     : $UUID"
  echo "  expire   : $EXP_ISO (UTC)"
  echo "  max_ip   : $MAXIP (tersimpan di $VLESS_LIMIT_DIR/$USERNAME.limit)"
  echo "  vless URL: $LINK"
  echo ""
  printf "Tekan ENTER untuk kembali ke menu..."
  IFS= read -r _ || true
  return 0
}

# === util tambahan ===
read_max_ip() {
  # kembalikan limit IP dari file, default 1
  U="$1"
  [ -f "$VLESS_LIMIT_DIR/$U.limit" ] && { tr -d '\r\n' < "$VLESS_LIMIT_DIR/$U.limit"; return; }
  echo 1
}

# === FUNGSI: Trial user VLESS (interaktif) ===
# Membuat user trial-YYYYMMDDHHMMSS
trial_user_vless() {
  ensure_layout

  # durasi jam
  while :; do
    printf "Durasi trial (jam) [default 24] (x=Kembali): "
    IFS= read -r HOURS || true
    case "${HOURS:-}" in
      '' ) HOURS="24" ;;
      x|X) echo "Dibatalkan. Kembali ke menu."; printf "Tekan ENTER untuk kembali..."; IFS= read -r _ || true; return 0 ;;
      *[!0-9]* ) echo "Harus angka bulat."; continue ;;
    esac
    break
  done

  # limit IP
  while :; do
    printf "Maksimal IP [default 1] (x=Kembali): "
    IFS= read -r MAXIP || true
    case "${MAXIP:-}" in
      '' ) MAXIP="1" ;;
      x|X) echo "Dibatalkan. Kembali ke menu."; printf "Tekan ENTER untuk kembali..."; IFS= read -r _ || true; return 0 ;;
      *[!0-9]* ) echo "Harus angka bulat." ; continue ;;
    esac
    break
  done

  USERNAME="trial-$(date +%Y%m%d%H%M%S)"
  UUID="$(uuidgen)"
  EXP_EPOCH="$(date -d "+$HOURS hours" +%s)"
  EXP_ISO="$(iso_from_epoch "$EXP_EPOCH")"

  cp -f "$CFG" "$BACKUP_DIR/config.json.bak.$(date +%F-%H%M%S)"
  TMP="$(mktemp)"
  jq --arg user "$USERNAME" --arg uuid "$UUID" --arg exp "$EXP_ISO" '
    .inbounds |= (map(
      if .protocol=="vless" then
        .settings.clients = ((.settings.clients // []) + [{ "id": $uuid, "email": $user, "expiry": $exp }])
      else . end
    ))
  ' "$CFG" > "$TMP" && mv "$TMP" "$CFG"

  save_meta "$USERNAME" "$UUID" "$EXP_EPOCH" "${HOURS}h" "$MAXIP"
  reload_xray

  LINK="$(build_vless_uri "$USERNAME" "$UUID")"
  echo ""
  echo "✅ Trial VLESS dibuat:"
  echo "  user     : $USERNAME"
  echo "  uuid     : $UUID"
  echo "  expire   : $EXP_ISO (UTC)"
  echo "  max_ip   : $MAXIP (tersimpan di $VLESS_LIMIT_DIR/$USERNAME.limit)"
  echo "  vless URL: $LINK"
  echo ""
  printf "Tekan ENTER untuk kembali ke menu..."
  IFS= read -r _ || true
  return 0
}

# === FUNGSI: Hapus user VLESS (interaktif) ===
delete_user_vless() {
  ensure_layout

  TMP_LIST="$(mktemp)"
  jq -r '
    .inbounds[]? | select(.protocol=="vless")
    | (.settings.clients // [])[]?
    | (.email // empty)
  ' "$CFG" 2>/dev/null | sort -u > "$TMP_LIST"

  COUNT=$(wc -l < "$TMP_LIST" | tr -d ' ')
  if [ "$COUNT" -eq 0 ]; then
    echo "  (tidak ada akun VLESS terdaftar)"
    echo ""
    printf "Tekan ENTER untuk kembali ke menu..."
    IFS= read -r _ || true
    rm -f "$TMP_LIST"
    return 0
  fi

  echo "Daftar akun VLESS:"
  awk '{ printf "  %2d) %s\n", NR, $0 }' "$TMP_LIST"
  echo "  x) Kembali ke menu"
  echo ""

  while :; do
    printf "Pilih nomor, ketik username, atau 'x' untuk kembali: "
    IFS= read -r SEL || true
    [ -n "${SEL:-}" ] || { echo "Tidak boleh kosong."; continue; }

    case "$SEL" in
      x|X)
        echo "Dibatalkan. Kembali ke menu."
        echo ""
        printf "Tekan ENTER untuk kembali..."
        IFS= read -r _ || true
        rm -f "$TMP_LIST"
        return 0
        ;;
      *[!0-9]*)
        USERNAME="$SEL"
        ;;
      *)
        if [ "$SEL" -ge 1 ] && [ "$SEL" -le "$COUNT" ]; then
          USERNAME="$(sed -n "${SEL}p" "$TMP_LIST")"
        else
          echo "Nomor di luar jangkauan (1-$COUNT)."
          continue
        fi
        ;;
    esac

    if user_exists "$USERNAME"; then
      break
    else
      echo "User '$USERNAME' tidak ditemukan di config."
    fi
  done

  printf "Yakin hapus user '%s'? [y/N]: " "$USERNAME"
  IFS= read -r CONFIRM || true
  case "$CONFIRM" in
    y|Y|yes|YES) : ;;
    *)
      echo "Dibatalkan."
      echo ""
      printf "Tekan ENTER untuk kembali ke menu..."
      IFS= read -r _ || true
      rm -f "$TMP_LIST"
      return 0
      ;;
  esac

  cp -f "$CFG" "$BACKUP_DIR/config.json.bak.$(date +%F-%H%M%S)"
  TMP="$(mktemp)"
  jq --arg user "$USERNAME" '
    .inbounds |= (map(
      if .protocol=="vless" then
        .settings.clients = ((.settings.clients // []) | map(select(.email != $user)))
      else . end
    ))
  ' "$CFG" > "$TMP" && mv "$TMP" "$CFG"

  rm -f "$VLESS_USERS_DIR/$USERNAME.json" "$VLESS_LIMIT_DIR/$USERNAME.limit" 2>/dev/null || true

  reload_xray
  echo "🗑️  User '$USERNAME' dihapus (termasuk metadata & file limit IP)."
  echo ""
  printf "Tekan ENTER untuk kembali ke menu..."
  IFS= read -r _ || true

  rm -f "$TMP_LIST"
  return 0
}

# === FUNGSI: Perpanjang user VLESS (interaktif) ===
renew_user_vless() {
  ensure_layout

  # tanya username (+ opsi x untuk kembali)
  while :; do
    printf "Username yang diperpanjang (x=Kembali): "
    IFS= read -r USERNAME || true
    case "${USERNAME:-}" in
      '' ) echo "Tidak boleh kosong."; continue ;;
      x|X)
        echo "Dibatalkan. Kembali ke menu."
        printf "Tekan ENTER untuk kembali..."
        IFS= read -r _ || true
        return 0
        ;;
    esac
    user_exists "$USERNAME" && break || echo "User '$USERNAME' tidak ditemukan."
  done

  # tanya hari tambahan (integer, tanpa desimal, max 99999) + opsi x untuk kembali
  while :; do
    printf "Tambahan hari (x=Kembali) : [default 30] "
    IFS= read -r ADD_DAYS || true

    case "${ADD_DAYS:-}" in
      '' ) ADD_DAYS="30" ;;           # default
      x|X)
        echo "Dibatalkan. Kembali ke menu."
        printf "Tekan ENTER untuk kembali..."
        IFS= read -r _ || true
        return 0
        ;;
    esac

    case "$ADD_DAYS" in
      *.*)  echo "Tidak boleh desimal (contoh valid: 1, 7, 30).";;
      *[!0-9]*|'') echo "Masukkan angka (0-99999).";;
      *)
        if [ "$ADD_DAYS" -gt 99999 ]; then
          echo "Maksimal 99999 hari."
        else
          break
        fi
        ;;
    esac
  done

  NOW="$(date +%s)"
  CURR_EXP="0"
  if [ -f "$VLESS_USERS_DIR/$USERNAME.json" ]; then
    CURR_EXP="$(jq -r '.expire_epoch // 0' "$VLESS_USERS_DIR/$USERNAME.json" 2>/dev/null || echo 0)"
  fi
  BASE_EPOCH="$NOW"
  [ "$CURR_EXP" -gt "$NOW" ] && BASE_EPOCH="$CURR_EXP"

  # Hindari format '@epoch + N days' (kadang error di BusyBox); pakai 2 langkah
  BASE_STR="$(date -u -d "@$BASE_EPOCH" '+%Y-%m-%d %H:%M:%S')"
  NEW_EXP_EPOCH="$(date -u -d "$BASE_STR + $ADD_DAYS days" +%s)"
  NEW_EXP_ISO="$(iso_from_epoch "$NEW_EXP_EPOCH")"

  # update config
  cp -f "$CFG" "$BACKUP_DIR/config.json.bak.$(date +%F-%H%M%S)"
  TMP="$(mktemp)"
  jq --arg user "$USERNAME" --arg exp "$NEW_EXP_ISO" '
    .inbounds |= (map(
      if .protocol=="vless" then
        .settings.clients = ((.settings.clients // []) | map(
          if .email==$user then .expiry=$exp else . end
        ))
      else . end
    ))
  ' "$CFG" > "$TMP" && mv "$TMP" "$CFG"

  UUID="$(uuid_of_user "$USERNAME")"
  [ -n "$UUID" ] || UUID="$(jq -r '.uuid // empty' "$VLESS_USERS_DIR/$USERNAME.json" 2>/dev/null || true)"
  MAXIP="$(read_max_ip "$USERNAME")"
  save_meta "$USERNAME" "${UUID:-unknown}" "$NEW_EXP_EPOCH" "+${ADD_DAYS}d" "$MAXIP"

  reload_xray
  echo "♻️  User '$USERNAME' diperpanjang sampai: $NEW_EXP_ISO (UTC)"
  echo ""
  printf "Tekan ENTER untuk kembali ke menu..."
  IFS= read -r _ || true
  return 0
}

# === FUNGSI: Tampilkan user yang login/aktif (interaktif) ===
show_login_user_vless() {
  # rentang menit
  while :; do
    printf "Rentang waktu (menit) [default 60] (x=Kembali): "
    IFS= read -r MINS || true
    case "${MINS:-}" in
      '' ) MINS="60" ;;
      x|X) echo "Dibatalkan. Kembali ke menu."; printf "Tekan ENTER untuk kembali..."; IFS= read -r _ || true; return 0 ;;
      *[!0-9]* ) echo "Harus angka bulat." ; continue ;;
    esac
    break
  done

  SINCE_STR="$MINS minutes ago"
  echo "Aktivitas login dalam $MINS menit terakhir:"

  if [ -f "$ACCESS_LOG" ]; then
    awk -v date_cut="$(date -d "$SINCE_STR" +%s)" '
      /email:[^ ]+/ {
        ts = 0
        match($0, /[0-9]{4}[-\/][0-9]{2}[-\/][0-9]{2}[ T][0-9]{2}:[0-9]{2}:[0-9]{2}/, t)
        if (t[0] != "") {
          gsub(/\//,"-", t[0])
          cmd = "date -d \"" t[0] "\" +%s"
          cmd | getline ts; close(cmd)
        }
        if (ts==0 || ts >= date_cut) {
          match($0, /email:([[:alnum:]_.@+-]+)/, m); user=m[1]
          match($0, /([0-9]{1,3}(\.[0-9]{1,3}){3})/, ip)
          if (user!="") { key=user"|"ip[1]; hits[key]++ }
        }
      }
      END {
        if (length(hits)==0) print "  (tidak ada login terdeteksi via access.log)"
        else {
          print "  user | ip | hits"
          for (k in hits) { split(k, a, "|"); printf "  %s | %s | %d\n", a[1], (a[2]==""?"-":a[2]), hits[k] }
        }
      }
    ' "$ACCESS_LOG"
  else
    journalctl -u "$XRAY_SERVICE" --since "$SINCE_STR" --no-pager 2>/dev/null \
    | awk '
      /email:[^ ]+/ {
        match($0, /email:([[:alnum:]_.@+-]+)/, m); user=m[1]
        match($0, /([0-9]{1,3}(\.[0-9]{1,3}){3})/, ip)
        if (user!="") { key=user"|"ip[1]; hits[key]++ }
      }
      END {
        if (length(hits)==0) print "  (tidak ada login terdeteksi via journal)"
        else {
          print "  user | ip | hits"
          for (k in hits) { split(k, a, "|"); printf "  %s | %s | %d\n", a[1], (a[2]==""?"-":a[2]), hits[k] }
        }
      }'
  fi

  echo ""
  printf "Tekan ENTER untuk kembali ke menu..."
  IFS= read -r _ || true
  return 0
}

# alias tetap
showlogin_user_vless() { show_login_user_vless; }

# alias nama sesuai permintaan (tanpa underscore)
showlogin_user_vless() { show_login_user_vless; }

# === FUNGSI: Tampilkan link & info akun VLESS (interaktif, tanpa isi metadata) ===
show_config_vless() {
  ensure_layout

  # Deteksi direktori metadata
  META_DIR="${VLESS_USERS_DIR:-${USERS_DIR:-/usr/local/etc/xray/users/vless}}"
  [ -d "$META_DIR" ] || META_DIR="/usr/local/etc/xray/users/vless"
  [ -d "$META_DIR" ] || META_DIR="/usr/local/etc/xray/user/vless"

  if [ ! -d "$META_DIR" ]; then
    echo "Folder metadata VLESS tidak ditemukan."
    echo "Pastikan berada di salah satu jalur berikut:"
    echo "  - /usr/local/etc/xray/users/vless"
    echo "  - /usr/local/etc/xray/user/vless"
    printf "Tekan ENTER untuk kembali..."
    IFS= read -r _ || true
    return 1
  fi

  # Kumpulkan daftar username
  TMP_LIST="$(mktemp)"
  {
    jq -r '
      .inbounds[]? | select(.protocol=="vless")
      | (.settings.clients // [])[]? | (.email // empty)
    ' "$CFG" 2>/dev/null
    find "$META_DIR" -maxdepth 1 -type f -name '*.json' -printf '%f\n' 2>/dev/null \
      | sed 's/\.json$//'
  } | awk 'NF' | sort -u > "$TMP_LIST"

  COUNT=$(wc -l < "$TMP_LIST" | tr -d ' ')
  if [ "$COUNT" -eq 0 ]; then
    echo "(tidak ada akun VLESS terdaftar)"
    printf "Tekan ENTER untuk kembali..."
    IFS= read -r _ || true
    rm -f "$TMP_LIST"
    return 0
  fi

  echo "Daftar akun VLESS:"
  awk '{ printf "  %2d) %s\n", NR, $0 }' "$TMP_LIST"
  echo "  x) Kembali"
  echo ""

  # Pilih akun
  local USERNAME
  while :; do
    printf "Pilih nomor, ketik username, atau 'x' untuk kembali: "
    IFS= read -r SEL || true
    [ -n "${SEL:-}" ] || { echo "Tidak boleh kosong."; continue; }

    case "$SEL" in
      x|X)
        echo "Kembali ke menu."
        printf "Tekan ENTER untuk kembali..."
        IFS= read -r _ || true
        rm -f "$TMP_LIST"
        return 0
        ;;
      *[!0-9]*)
        USERNAME="$SEL"
        ;;
      *)
        if [ "$SEL" -ge 1 ] && [ "$SEL" -le "$COUNT" ]; then
          USERNAME="$(sed -n "${SEL}p" "$TMP_LIST")"
        else
          echo "Nomor di luar jangkauan (1-$COUNT)."
          continue
        fi
        ;;
    esac

    if user_exists "$USERNAME" || [ -f "$META_DIR/$USERNAME.json" ]; then
      break
    else
      echo "User '$USERNAME' tidak ditemukan."
    fi
  done

  UUID="$(uuid_of_user "$USERNAME")"
  [ -z "$UUID" ] && [ -f "$META_DIR/$USERNAME.json" ] && \
    UUID="$(jq -r '.uuid // empty' "$META_DIR/$USERNAME.json" 2>/dev/null || true)"

  LINK="# (UUID tidak ditemukan)"
  [ -n "$UUID" ] && LINK="$(build_vless_uri "$USERNAME" "$UUID")"

  META_EXP_ISO=""
  [ -f "$META_DIR/$USERNAME.json" ] && \
    META_EXP_ISO="$(jq -r '.expire_iso // empty' "$META_DIR/$USERNAME.json" 2>/dev/null || true)"

  MAXIP="$(read_max_ip "$USERNAME")"

  echo ""
  echo "✅ Informasi Akun VLESS"
  echo "  Username : $USERNAME"
  echo "  UUID     : ${UUID:-tidak ada}"
  [ -n "$META_EXP_ISO" ] && echo "  Expire   : $META_EXP_ISO (UTC)"
  echo "  Max IP   : $MAXIP"
  echo "  VLESS URL: $LINK"
  echo ""
  printf "Tekan ENTER untuk kembali..."
  IFS= read -r _ || true

  rm -f "$TMP_LIST"
  return 0
}
# === Guard: hanya auto-jalankan kalau file ini dieksekusi langsung, bukan di-source ===
if [ "${BASH_SOURCE:-$0}" = "$0" ]; then
  add_user_vless "$@"
fi

