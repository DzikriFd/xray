#!/usr/bin/env sh

XRAY_SERVICE="xray"
CFG="/usr/local/etc/xray/config.json"
TROJAN_USERS_DIR="/usr/local/etc/xray/users/trojan"
TROJAN_LIMIT_DIR="/etc/trojan/limit_ip"
BACKUP_DIR="/usr/local/etc/xray/backup"
ACCESS_LOG="/var/log/xray/access.log"
DATE_FMT="%Y-%m-%d %H:%M:%S %Z"

require_cmd(){ for c in "$@"; do command -v "$c" >/dev/null 2>&1 || { echo "ERROR: butuh '$c'"; exit 1; }; done; }
require_root(){ [ "$(id -u)" -eq 0 ] || { echo "Harus root"; exit 1; }; }
ensure_layout(){ require_cmd jq date openssl || true; require_root; [ -f "$CFG" ] || { echo "Config tidak ditemukan: $CFG"; exit 1; }; mkdir -p "$TROJAN_USERS_DIR" "$TROJAN_LIMIT_DIR" "$BACKUP_DIR"; }

epoch_plus_days(){ date -d "+$1 days" +%s; }
iso_from_epoch(){ date -u -d "@$1" +"%Y-%m-%dT%H:%M:%SZ"; }

user_exists_trojan(){
  jq -e --arg user "$1" '
    [ .inbounds[]? | select(.protocol=="trojan")
      | (.settings.clients // [])[]?
      | select(.email==$user)
    ] | length > 0
  ' "$CFG" >/dev/null 2>&1
}

pass_of_user_trojan(){
  jq -r --arg user "$1" '
    [ .inbounds[]? | select(.protocol=="trojan")
      | (.settings.clients // [])[]?
      | select(.email==$user) | .password
    ][0] // empty
  ' "$CFG"
}

first_trojan_inbound(){ jq -r '(.inbounds[]? | select(.protocol=="trojan")) | @base64' "$CFG" | head -n1; }
b64json(){ printf "%s" "$1" | base64 -d; }

detect_host_from_inbound(){
  IN="$1"
  SNI=$(printf "%s" "$IN" | jq -r '.streamSettings.tlsSettings.serverName // .streamSettings.realitySettings.serverNames[0] // empty')
  if [ -n "${XRAY_HOST:-}" ]; then echo "$XRAY_HOST"
  elif [ -n "$SNI" ] && [ "$SNI" != "null" ]; then echo "$SNI"
  else
    for f in /usr/local/etc/xray/domain /etc/xray/domain /etc/v2ray/domain; do
      [ -f "$f" ] && { tr -d '\r\n' < "$f"; echo; return; }
    done
    if command -v curl >/dev/null 2>&1; then PUB="$(curl -fsS --max-time 2 https://ifconfig.me || true)"; [ -n "$PUB" ] && { echo "$PUB"; return; }; fi
    hostname -I 2>/dev/null | awk '{print $1}' | tr -d ' ' || echo "127.0.0.1"
  fi
}

build_trojan_uri(){
  USER="$1"; PASS="$2"
  B64="$(first_trojan_inbound || true)"; [ -n "$B64" ] || { echo "# inbound TROJAN tidak ditemukan"; return; }
  J="$(b64json "$B64")"

  HOST="$(detect_host_from_inbound "$J")"
  PORT="$(printf "%s" "$J" | jq -r '.port // "443"')"
  NET="$(printf "%s" "$J" | jq -r '.streamSettings.network // "tcp"')"
  SEC="$(printf "%s" "$J" | jq -r '.streamSettings.security // "tls"')"
  WSPATH="$(printf "%s" "$J" | jq -r '.streamSettings.wsSettings.path // ""')"
  WSHOST="$(printf "%s" "$J" | jq -r '.streamSettings.wsSettings.headers.Host // ""')"
  SNI="$(printf "%s" "$J" | jq -r '.streamSettings.tlsSettings.serverName // .streamSettings.realitySettings.serverNames[0] // ""')"
  GRPC_SVC="$(printf "%s" "$J" | jq -r '.streamSettings.grpcSettings.serviceName // ""')"
  REALITY_PBK="$(printf "%s" "$J" | jq -r '.streamSettings.realitySettings.publicKey // ""')"
  REALITY_SID="$(printf "%s" "$J" | jq -r '.streamSettings.realitySettings.shortId // ""')"

  QP="type=$NET"
  if [ "$SEC" = "tls" ]; then
    QP="$QP&security=tls"; [ -n "$SNI" ] && QP="$QP&sni=$SNI"
  elif [ "$SEC" = "reality" ]; then
    QP="$QP&security=reality"; [ -n "$REALITY_PBK" ] && QP="$QP&pbk=$REALITY_PBK"; [ -n "$REALITY_SID" ] && QP="$QP&sid=$REALITY_SID"; [ -n "$SNI" ] && QP="$QP&sni=$SNI"
  fi
  case "$NET" in
    ws) [ -n "$WSPATH" ] && QP="$QP&path=$(printf "%s" "$WSPATH" | sed 's#^/#%2F#')"; [ -n "$WSHOST" ] && QP="$QP&host=$WSHOST" ;;
    grpc) [ -n "$GRPC_SVC" ] && QP="$QP&serviceName=$GRPC_SVC&mode=gun" ;;
  esac

  echo "trojan://${PASS}@${HOST}:${PORT}?${QP}#${USER}"
}

save_meta_trojan(){
  USER="$1"; PASS="$2"; EXP_EPOCH="$3"; DUR="$4"; MAXIP="$5"
  EXP_ISO="$(iso_from_epoch "$EXP_EPOCH")"
  mkdir -p "$TROJAN_USERS_DIR" "$TROJAN_LIMIT_DIR"
  cat > "$TROJAN_USERS_DIR/$USER.json" <<EOF
{"username":"$USER","password":"$PASS","expire_epoch":$EXP_EPOCH,"expire_iso":"$EXP_ISO","updated_at":"$(date +"$DATE_FMT")","duration":"$DUR","max_ip":$MAXIP}
EOF
  echo "$MAXIP" > "$TROJAN_LIMIT_DIR/$USER.limit"
}

reload_xray(){ if systemctl reload "$XRAY_SERVICE" 2>/dev/null; then echo "Service $XRAY_SERVICE di-reload."; else systemctl restart "$XRAY_SERVICE"; echo "Service $XRAY_SERVICE di-restart."; fi; }
read_max_ip_trojan(){ U="$1"; [ -f "$TROJAN_LIMIT_DIR/$U.limit" ] && tr -d '\r\n' < "$TROJAN_LIMIT_DIR/$U.limit" || echo 1; }

rand_pass(){ if command -v openssl >/dev/null 2>&1; then openssl rand -hex 12; else uuidgen; fi; }

# === ADD ===
add_user_trojan(){
  ensure_layout
  while :; do
    printf "Username (x=Kembali): "; IFS= read -r USERNAME || true
    case "${USERNAME:-}" in '' ) echo "Tidak boleh kosong."; continue ;; x|X) echo "Dibatalkan."; printf "ENTER..."; IFS= read -r _ || true; return 0 ;; esac
    if user_exists_trojan "$USERNAME"; then echo "User '$USERNAME' sudah ada."; continue; fi; break
  done
  while :; do
    printf "Masa berlaku (hari) [30] (x=Kembali): "; IFS= read -r DAYS || true
    case "${DAYS:-}" in '' ) DAYS="30" ;; x|X) echo "Dibatalkan."; printf "ENTER..."; IFS= read -r _ || true; return 0 ;; *[!0-9]* ) echo "Harus angka bulat." ; continue ;; esac; break
  done
  while :; do
    printf "Maksimal IP [1] (x=Kembali): "; IFS= read -r MAXIP || true
    case "${MAXIP:-}" in '' ) MAXIP="1" ;; x|X) echo "Dibatalkan."; printf "ENTER..."; IFS= read -r _ || true; return 0 ;; *[!0-9]* ) echo "Harus angka bulat." ; continue ;; esac; break
  done

  PASS="$(rand_pass)"; EXP_EPOCH="$(epoch_plus_days "$DAYS")"; EXP_ISO="$(iso_from_epoch "$EXP_EPOCH")"

  cp -f "$CFG" "$BACKUP_DIR/config.json.bak.$(date +%F-%H%M%S)"; TMP="$(mktemp)"
  jq --arg user "$USERNAME" --arg pass "$PASS" --arg exp "$EXP_ISO" '
    .inbounds |= (map(if .protocol=="trojan" then
      .settings.clients = ((.settings.clients // []) + [{ "password": $pass, "email": $user, "expiry": $exp }])
    else . end))' "$CFG" > "$TMP" && mv "$TMP" "$CFG"

  save_meta_trojan "$USERNAME" "$PASS" "$EXP_EPOCH" "${DAYS}d" "$MAXIP"; reload_xray
  LINK="$(build_trojan_uri "$USERNAME" "$PASS")"
  echo ""; echo "✅ TROJAN user dibuat: $USERNAME"; echo "  Link: $LINK"; echo ""
  printf "Tekan ENTER untuk kembali ke menu..."; IFS= read -r _ || true; return 0
}

# === TRIAL ===
trial_user_trojan(){
  ensure_layout
  while :; do
    printf "Durasi trial (jam) [24] (x=Kembali): "; IFS= read -r HOURS || true
    case "${HOURS:-}" in '' ) HOURS="24" ;; x|X) echo "Batal."; printf "ENTER..."; IFS= read -r _ || true; return 0 ;; *[!0-9]* ) echo "Harus angka bulat." ;; *) break ;; esac
  done
  while :; do
    printf "Maksimal IP [1] (x=Kembali): "; IFS= read -r MAXIP || true
    case "${MAXIP:-}" in '' ) MAXIP="1" ;; x|X) echo "Batal."; printf "ENTER..."; IFS= read -r _ || true; return 0 ;; *[!0-9]* ) echo "Harus angka bulat." ;; *) break ;; esac
  done

  USERNAME="trial-$(date +%Y%m%d%H%M%S)"; PASS="$(rand_pass)"
  EXP_EPOCH="$(date -d "+$HOURS hours" +%s)"; EXP_ISO="$(iso_from_epoch "$EXP_EPOCH")"

  cp -f "$CFG" "$BACKUP_DIR/config.json.bak.$(date +%F-%H%M%S)"; TMP="$(mktemp)"
  jq --arg user "$USERNAME" --arg pass "$PASS" --arg exp "$EXP_ISO" '
    .inbounds |= (map(if .protocol=="trojan" then
      .settings.clients = ((.settings.clients // []) + [{ "password": $pass, "email": $user, "expiry": $exp }])
    else . end))' "$CFG" > "$TMP" && mv "$TMP" "$CFG"

  save_meta_trojan "$USERNAME" "$PASS" "$EXP_EPOCH" "${HOURS}h" "$MAXIP"; reload_xray
  LINK="$(build_trojan_uri "$USERNAME" "$PASS")"
  echo ""; echo "✅ Trial TROJAN dibuat: $USERNAME"; echo "  Link: $LINK"; echo ""
  printf "Tekan ENTER untuk kembali ke menu..."; IFS= read -r _ || true; return 0
}

# === DELETE ===
delete_user_trojan(){
  ensure_layout
  TMP_LIST="$(mktemp)"
  jq -r '.inbounds[]?|select(.protocol=="trojan")|(.settings.clients//[])[]?|.email//empty' "$CFG" | sort -u > "$TMP_LIST"
  COUNT=$(wc -l < "$TMP_LIST" | tr -d ' ')
  if [ "$COUNT" -eq 0 ]; then echo "  (belum ada user TROJAN)"; printf "ENTER..."; IFS= read -r _ || true; rm -f "$TMP_LIST"; return 0; fi
  echo "Daftar akun TROJAN:"; awk '{printf "  %2d) %s\n",NR,$0}' "$TMP_LIST"; echo "  x) Kembali"; echo ""

  while :; do
    printf "Pilih nomor/ketik username (x=Kembali): "; IFS= read -r SEL || true
    [ -n "${SEL:-}" ] || { echo "Tidak boleh kosong."; continue; }
    case "$SEL" in
      x|X) echo "Batal."; printf "ENTER..."; IFS= read -r _ || true; rm -f "$TMP_LIST"; return 0 ;;
      *[!0-9]* ) USERNAME="$SEL" ;;
      * ) if [ "$SEL" -ge 1 ] && [ "$SEL" -le "$COUNT" ]; then USERNAME="$(sed -n "${SEL}p" "$TMP_LIST")"; else echo "Diluar jangkauan."; continue; fi ;;
    esac
    user_exists_trojan "$USERNAME" && break || echo "User tidak ditemukan."
  done

  printf "Yakin hapus '%s'? [y/N]: " "$USERNAME"; IFS= read -r OK || true
  case "$OK" in y|Y|yes|YES) : ;; *) echo "Batal."; printf "ENTER..."; IFS= read -r _ || true; rm -f "$TMP_LIST"; return 0 ;; esac

  cp -f "$CFG" "$BACKUP_DIR/config.json.bak.$(date +%F-%H%M%S)"; TMP="$(mktemp)"
  jq --arg user "$USERNAME" '.inbounds |= (map(if .protocol=="trojan" then .settings.clients=((.settings.clients//[])|map(select(.email!=$user))) else . end))' "$CFG" > "$TMP" && mv "$TMP" "$CFG"

  rm -f "$TROJAN_USERS_DIR/$USERNAME.json" "$TROJAN_LIMIT_DIR/$USERNAME.limit" 2>/dev/null || true
  reload_xray; echo "🗑️  User '$USERNAME' dihapus."; printf "ENTER..."; IFS= read -r _ || true; rm -f "$TMP_LIST"; return 0
}

# === RENEW ===
renew_user_trojan(){
  ensure_layout
  while :; do
    printf "Username diperpanjang (x=Kembali): "; IFS= read -r USERNAME || true
    case "${USERNAME:-}" in '' ) echo "Tidak boleh kosong."; continue ;; x|X) echo "Batal."; printf "ENTER..."; IFS= read -r _ || true; return 0 ;; esac
    user_exists_trojan "$USERNAME" && break || echo "User tidak ditemukan."
  done
  while :; do
    printf "Tambahan hari [30] (x=Kembali): "; IFS= read -r ADD_DAYS || true
    case "${ADD_DAYS:-}" in '' ) ADD_DAYS="30" ;; x|X) echo "Batal."; printf "ENTER..."; IFS= read -r _ || true; return 0 ;; *.*) echo "Tidak boleh desimal." ;; *[!0-9]* ) echo "Masukkan angka 0-99999." ;; *) [ "$ADD_DAYS" -le 99999 ] || { echo "Maks 99999."; continue; }; break ;; esac
  done
  NOW="$(date +%s)"; CURR_EXP="0"
  [ -f "$TROJAN_USERS_DIR/$USERNAME.json" ] && CURR_EXP="$(jq -r '.expire_epoch//0' "$TROJAN_USERS_DIR/$USERNAME.json" 2>/dev/null || echo 0)"
  BASE_EPOCH="$NOW"; [ "$CURR_EXP" -gt "$NOW" ] && BASE_EPOCH="$CURR_EXP"
  BASE_STR="$(date -u -d "@$BASE_EPOCH" '+%Y-%m-%d %H:%M:%S')"
  NEW_EXP_EPOCH="$(date -u -d "$BASE_STR + $ADD_DAYS days" +%s)"; NEW_EXP_ISO="$(iso_from_epoch "$NEW_EXP_EPOCH")"

  cp -f "$CFG" "$BACKUP_DIR/config.json.bak.$(date +%F-%H%M%S)"; TMP="$(mktemp)"
  jq --arg user "$USERNAME" --arg exp "$NEW_EXP_ISO" '.inbounds |= (map(if .protocol=="trojan" then .settings.clients=((.settings.clients//[])|map(if .email==$user then .expiry=$exp else . end)) else . end))' "$CFG" > "$TMP" && mv "$TMP" "$CFG"

  PASS="$(pass_of_user_trojan "$USERNAME")"; [ -n "$PASS" ] || PASS="$(jq -r '.password//empty' "$TROJAN_USERS_DIR/$USERNAME.json" 2>/dev/null || true)"
  MAXIP="$(read_max_ip_trojan "$USERNAME")"
  save_meta_trojan "$USERNAME" "${PASS:-unknown}" "$NEW_EXP_EPOCH" "+${ADD_DAYS}d" "$MAXIP"
  reload_xray; echo "♻️  Diperpanjang s.d. $NEW_EXP_ISO (UTC)"; printf "ENTER..."; IFS= read -r _ || true; return 0
}

# === SHOW LOGIN ===
show_login_user_trojan(){
  while :; do
    printf "Rentang menit [60] (x=Kembali): "; IFS= read -r MINS || true
    case "${MINS:-}" in '' ) MINS="60" ;; x|X) echo "Batal."; printf "ENTER..."; IFS= read -r _ || true; return 0 ;; *[!0-9]* ) echo "Harus angka bulat." ;; *) break ;; esac
  done
  SINCE_STR="$MINS minutes ago"; echo "Aktivitas login $MINS menit terakhir:"
  if [ -f "$ACCESS_LOG" ]; then
    awk -v date_cut="$(date -d "$SINCE_STR" +%s)" '
      /email:[^ ]+/ { ts=0; match($0,/[0-9]{4}[-\/][0-9]{2}[-\/][0-9]{2}[ T][0-9]{2}:[0-9]{2}:[0-9]{2}/,t);
        if(t[0]!=""){gsub(/\//,"-",t[0]); cmd="date -d \"" t[0] "\" +%s"; cmd|getline ts; close(cmd)}
        if(ts==0 || ts>=date_cut){ match($0,/email:([[:alnum:]_.@+-]+)/,m); user=m[1]; match($0,/([0-9]{1,3}(\.[0-9]{1,3}){3})/,ip); if(user!=""){ key=user"|"ip[1]; hits[key]++ } }
      }
      END{ if(length(hits)==0) print "  (tidak ada login via access.log)"; else { print "  user | ip | hits"; for(k in hits){split(k,a,"|"); printf "  %s | %s | %d\n",a[1],(a[2]==""?"-":a[2]),hits[k]} } }
    ' "$ACCESS_LOG"
  else
    journalctl -u "$XRAY_SERVICE" --since "$SINCE_STR" --no-pager 2>/dev/null | awk '
      /email:[^ ]+/ { match($0,/email:([[:alnum:]_.@+-]+)/,m); user=m[1]; match($0,/([0-9]{1,3}(\.[0-9]{1,3}){3})/,ip); if(user!=""){ key=user"|"ip[1]; hits[key]++ } }
      END{ if(length(hits)==0) print "  (tidak ada login via journal)"; else { print "  user | ip | hits"; for(k in hits){split(k,a,"|"); printf "  %s | %s | %d\n",a[1],(a[2]==""?"-":a[2]),hits[k]} } }
    '
  fi
  echo ""; printf "Tekan ENTER untuk kembali ke menu..."; IFS= read -r _ || true; return 0
}

# Guard
if [ "${BASH_SOURCE:-$0}" = "$0" ]; then add_user_trojan "$@"; fi
