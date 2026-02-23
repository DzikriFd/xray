#!/usr/bin/env sh

# === KONFIG ===
XRAY_SERVICE="xray"
CFG="/usr/local/etc/xray/config.json"
USERS_DIR="/usr/local/etc/xray/users/vmess"
LIMIT_DIR="/etc/vmess/limit_ip"
BACKUP_DIR="/usr/local/etc/xray/backup"
ACCESS_LOG="/var/log/xray/access.log"
DATE_FMT="%Y-%m-%d %H:%M:%S %Z"

# === UTIL ===
require_cmd() { for c in "$@"; do command -v "$c" >/dev/null 2>&1 || { echo "ERROR: butuh '$c'"; exit 1; }; done; }
require_root() { [ "$(id -u)" -eq 0 ] || { echo "Harus root"; exit 1; }; }
ensure_layout() {
  require_cmd jq uuidgen date base64 || true
  require_root
  [ -f "$CFG" ] || { echo "Config tidak ditemukan: $CFG"; exit 1; }
  mkdir -p "$USERS_DIR" "$LIMIT_DIR" "$BACKUP_DIR"
}
epoch_plus_days(){ date -d "+$1 days" +%s; }
iso_from_epoch(){ date -u -d "@$1" +"%Y-%m-%dT%H:%M:%SZ"; }

b64enc(){  # POSIX-safe base64 (fallback openssl)
  if command -v base64 >/dev/null 2>&1; then base64 -w0
  elif command -v openssl >/dev/null 2>&1; then openssl base64 -A
  else cat
  fi
}

user_exists_vmess() {
  jq -e --arg user "$1" '
    [ .inbounds[]? | select(.protocol=="vmess")
      | (.settings.clients // [])[]?
      | select(.email==$user)
    ] | length > 0
  ' "$CFG" >/dev/null 2>&1
}

uuid_of_user_vmess() {
  jq -r --arg user "$1" '
    [ .inbounds[]? | select(.protocol=="vmess")
      | (.settings.clients // [])[]?
      | select(.email==$user) | .id
    ][0] // empty
  ' "$CFG"
}

first_vmess_inbound(){ jq -r '(.inbounds[]? | select(.protocol=="vmess")) | @base64' "$CFG" | head -n1; }
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

build_vmess_uri(){
  USER="$1"; UUID="$2"
  B64="$(first_vmess_inbound || true)"; [ -n "$B64" ] || { echo "# inbound VMESS tidak ditemukan"; return; }
  J="$(b64json "$B64")"

  ADDR="$(detect_host_from_inbound "$J")"
  PORT="$(printf "%s" "$J" | jq -r '.port // "443"')"
  NET="$(printf "%s" "$J" | jq -r '.streamSettings.network // "tcp"')"
  SEC="$(printf "%s" "$J" | jq -r '.streamSettings.security // ""')"
  WSPATH="$(printf "%s" "$J" | jq -r '.streamSettings.wsSettings.path // ""')"
  WSHOST="$(printf "%s" "$J" | jq -r '.streamSettings.wsSettings.headers.Host // ""')"
  GRPC_SVC="$(printf "%s" "$J" | jq -r '.streamSettings.grpcSettings.serviceName // ""')"
  SNI="$(printf "%s" "$J" | jq -r '.streamSettings.tlsSettings.serverName // ""')"

  # vmess json (v2rayN-compatible)
  VMESS_JSON=$(cat <<JSON
{"v":"2","ps":"$USER","add":"$ADDR","port":"$PORT","id":"$UUID","aid":"0","scy":"auto","net":"$NET","type":"none","host":"$WSHOST","path":"$WSPATH","tls":"$SEC","sni":"$SNI","alpn":""}
JSON
)
  echo "vmess://$(printf "%s" "$VMESS_JSON" | b64enc)"
}

save_meta_vmess(){
  USER="$1"; UUID="$2"; EXP_EPOCH="$3"; DUR="$4"; MAXIP="$5"
  EXP_ISO="$(iso_from_epoch "$EXP_EPOCH")"
  mkdir -p "$USERS_DIR" "$LIMIT_DIR"
  cat > "$USERS_DIR/$USER.json" <<EOF
{"username":"$USER","uuid":"$UUID","expire_epoch":$EXP_EPOCH,"expire_iso":"$EXP_ISO","updated_at":"$(date +"$DATE_FMT")","duration":"$DUR","max_ip":$MAXIP}
EOF
  echo "$MAXIP" > "$LIMIT_DIR/$USER.limit"
}

reload_xray(){
  if systemctl reload "$XRAY_SERVICE" 2>/dev/null; then echo "Service $XRAY_SERVICE di-reload."
  else systemctl restart "$XRAY_SERVICE"; echo "Service $XRAY_SERVICE di-restart."; fi
}

read_max_ip_vmess(){ U="$1"; [ -f "$LIMIT_DIR/$U.limit" ] && tr -d '\r\n' < "$LIMIT_DIR/$U.limit" || echo 1; }

# === ADD (interaktif, x=Kembali) ===
add_user_vmess(){
  ensure_layout
  # username
  while :; do
    printf "Username (x=Kembali): "; IFS= read -r USERNAME || true
    case "${USERNAME:-}" in '' ) echo "Tidak boleh kosong."; continue ;; x|X) echo "Dibatalkan."; printf "ENTER untuk kembali..."; IFS= read -r _ || true; return 0;; esac
    if user_exists_vmess "$USERNAME"; then echo "User '$USERNAME' sudah ada."; continue; fi; break
  done
  # hari
  while :; do
    printf "Masa berlaku (hari) [30] (x=Kembali): "; IFS= read -r DAYS || true
    case "${DAYS:-}" in '' ) DAYS="30" ;; x|X) echo "Dibatalkan."; printf "ENTER..."; IFS= read -r _ || true; return 0 ;; *[!0-9]* ) echo "Harus angka bulat."; continue ;; esac; break
  done
  # limit ip
  while :; do
    printf "Maksimal IP [1] (x=Kembali): "; IFS= read -r MAXIP || true
    case "${MAXIP:-}" in '' ) MAXIP="1" ;; x|X) echo "Dibatalkan."; printf "ENTER..."; IFS= read -r _ || true; return 0 ;; *[!0-9]* ) echo "Harus angka bulat."; continue ;; esac; break
  done

  UUID="$(uuidgen)"
  EXP_EPOCH="$(epoch_plus_days "$DAYS")"; EXP_ISO="$(iso_from_epoch "$EXP_EPOCH")"

  cp -f "$CFG" "$BACKUP_DIR/config.json.bak.$(date +%F-%H%M%S)"; TMP="$(mktemp)"
  jq --arg user "$USERNAME" --arg uuid "$UUID" --arg exp "$EXP_ISO" '
    .inbounds |= (map(if .protocol=="vmess" then
      .settings.clients = ((.settings.clients // []) + [{ "id": $uuid, "email": $user, "expiry": $exp, "alterId": 0 }])
    else . end))' "$CFG" > "$TMP" && mv "$TMP" "$CFG"

  save_meta_vmess "$USERNAME" "$UUID" "$EXP_EPOCH" "${DAYS}d" "$MAXIP"
  reload_xray

  LINK="$(build_vmess_uri "$USERNAME" "$UUID")"
  echo ""; echo "✅ VMESS user dibuat untuk '$USERNAME'"; echo "  Link: $LINK"; echo ""
  printf "Tekan ENTER untuk kembali ke menu..."; IFS= read -r _ || true; return 0
}

# === TRIAL (jam) ===
trial_user_vmess(){
  ensure_layout
  while :; do
    printf "Durasi trial (jam) [24] (x=Kembali): "; IFS= read -r HOURS || true
    case "${HOURS:-}" in '' ) HOURS="24" ;; x|X) echo "Dibatalkan."; printf "ENTER..."; IFS= read -r _ || true; return 0 ;; *[!0-9]* ) echo "Harus angka bulat."; continue ;; esac; break
  done
  while :; do
    printf "Maksimal IP [1] (x=Kembali): "; IFS= read -r MAXIP || true
    case "${MAXIP:-}" in '' ) MAXIP="1" ;; x|X) echo "Dibatalkan."; printf "ENTER..."; IFS= read -r _ || true; return 0 ;; *[!0-9]* ) echo "Harus angka bulat."; continue ;; esac; break
  done

  USERNAME="trial-$(date +%Y%m%d%H%M%S)"; UUID="$(uuidgen)"
  EXP_EPOCH="$(date -d "+$HOURS hours" +%s)"; EXP_ISO="$(iso_from_epoch "$EXP_EPOCH")"

  cp -f "$CFG" "$BACKUP_DIR/config.json.bak.$(date +%F-%H%M%S)"; TMP="$(mktemp)"
  jq --arg user "$USERNAME" --arg uuid "$UUID" --arg exp "$EXP_ISO" '
    .inbounds |= (map(if .protocol=="vmess" then
      .settings.clients = ((.settings.clients // []) + [{ "id": $uuid, "email": $user, "expiry": $exp, "alterId": 0 }])
    else . end))' "$CFG" > "$TMP" && mv "$TMP" "$CFG"

  save_meta_vmess "$USERNAME" "$UUID" "$EXP_EPOCH" "${HOURS}h" "$MAXIP"; reload_xray
  LINK="$(build_vmess_uri "$USERNAME" "$UUID")"
  echo ""; echo "✅ Trial VMESS dibuat: $USERNAME"; echo "  Link: $LINK"; echo ""
  printf "Tekan ENTER untuk kembali ke menu..."; IFS= read -r _ || true; return 0
}

# === DELETE ===
delete_user_vmess(){
  ensure_layout
  TMP_LIST="$(mktemp)"
  jq -r '.inbounds[]?|select(.protocol=="vmess")|(.settings.clients//[])[]?|.email//empty' "$CFG" | sort -u > "$TMP_LIST"
  COUNT=$(wc -l < "$TMP_LIST" | tr -d ' ')
  if [ "$COUNT" -eq 0 ]; then echo "  (belum ada user VMESS)"; printf "ENTER..."; IFS= read -r _ || true; rm -f "$TMP_LIST"; return 0; fi

  echo "Daftar akun VMESS:"; awk '{printf "  %2d) %s\n",NR,$0}' "$TMP_LIST"; echo "  x) Kembali"; echo ""
  while :; do
    printf "Pilih nomor/ketik username (x=Kembali): "; IFS= read -r SEL || true
    [ -n "${SEL:-}" ] || { echo "Tidak boleh kosong."; continue; }
    case "$SEL" in
      x|X) echo "Dibatalkan."; printf "ENTER..."; IFS= read -r _ || true; rm -f "$TMP_LIST"; return 0 ;;
      *[!0-9]* ) USERNAME="$SEL" ;;
      * ) if [ "$SEL" -ge 1 ] && [ "$SEL" -le "$COUNT" ]; then USERNAME="$(sed -n "${SEL}p" "$TMP_LIST")"; else echo "Diluar jangkauan."; continue; fi ;;
    esac
    user_exists_vmess "$USERNAME" && break || echo "User tidak ditemukan."
  done

  printf "Yakin hapus '%s'? [y/N]: " "$USERNAME"; IFS= read -r OK || true
  case "$OK" in y|Y|yes|YES) : ;; *) echo "Batal."; printf "ENTER..."; IFS= read -r _ || true; rm -f "$TMP_LIST"; return 0 ;; esac

  cp -f "$CFG" "$BACKUP_DIR/config.json.bak.$(date +%F-%H%M%S)"; TMP="$(mktemp)"
  jq --arg user "$USERNAME" '.inbounds |= (map(if .protocol=="vmess" then .settings.clients=((.settings.clients//[])|map(select(.email!=$user))) else . end))' "$CFG" > "$TMP" && mv "$TMP" "$CFG"

  rm -f "$USERS_DIR/$USERNAME.json" "$LIMIT_DIR/$USERNAME.limit" 2>/dev/null || true
  reload_xray; echo "🗑️  User '$USERNAME' dihapus."; printf "ENTER..."; IFS= read -r _ || true; rm -f "$TMP_LIST"; return 0
}

# === RENEW ===
renew_user_vmess(){
  ensure_layout
  while :; do
    printf "Username diperpanjang (x=Kembali): "; IFS= read -r USERNAME || true
    case "${USERNAME:-}" in '' ) echo "Tidak boleh kosong."; continue ;; x|X) echo "Batal."; printf "ENTER..."; IFS= read -r _ || true; return 0 ;; esac
    user_exists_vmess "$USERNAME" && break || echo "User tidak ditemukan."
  done
  while :; do
    printf "Tambahan hari [30] (x=Kembali): "; IFS= read -r ADD_DAYS || true
    case "${ADD_DAYS:-}" in '' ) ADD_DAYS="30" ;; x|X) echo "Batal."; printf "ENTER..."; IFS= read -r _ || true; return 0 ;; *.*) echo "Tidak boleh desimal.";; *[!0-9]* ) echo "Masukkan angka 0-99999.";; *) [ "$ADD_DAYS" -le 99999 ] || { echo "Maks 99999."; continue; } ; break ;; esac
  done
  NOW="$(date +%s)"; CURR_EXP="0"
  [ -f "$USERS_DIR/$USERNAME.json" ] && CURR_EXP="$(jq -r '.expire_epoch//0' "$USERS_DIR/$USERNAME.json" 2>/dev/null || echo 0)"
  BASE_EPOCH="$NOW"; [ "$CURR_EXP" -gt "$NOW" ] && BASE_EPOCH="$CURR_EXP"
  BASE_STR="$(date -u -d "@$BASE_EPOCH" '+%Y-%m-%d %H:%M:%S')"
  NEW_EXP_EPOCH="$(date -u -d "$BASE_STR + $ADD_DAYS days" +%s)"; NEW_EXP_ISO="$(iso_from_epoch "$NEW_EXP_EPOCH")"

  cp -f "$CFG" "$BACKUP_DIR/config.json.bak.$(date +%F-%H%M%S)"; TMP="$(mktemp)"
  jq --arg user "$USERNAME" --arg exp "$NEW_EXP_ISO" '.inbounds |= (map(if .protocol=="vmess" then .settings.clients=((.settings.clients//[])|map(if .email==$user then .expiry=$exp else . end)) else . end))' "$CFG" > "$TMP" && mv "$TMP" "$CFG"

  UUID="$(uuid_of_user_vmess "$USERNAME")"; [ -n "$UUID" ] || UUID="$(jq -r '.uuid//empty' "$USERS_DIR/$USERNAME.json" 2>/dev/null || true)"
  MAXIP="$(read_max_ip_vmess "$USERNAME")"
  save_meta_vmess "$USERNAME" "${UUID:-unknown}" "$NEW_EXP_EPOCH" "+${ADD_DAYS}d" "$MAXIP"
  reload_xray; echo "♻️  Diperpanjang s.d. $NEW_EXP_ISO (UTC)"; printf "ENTER..."; IFS= read -r _ || true; return 0
}

# === SHOW LOGIN (sama pola) ===
show_login_user_vmess(){
  while :; do
    printf "Rentang menit [60] (x=Kembali): "; IFS= read -r MINS || true
    case "${MINS:-}" in '' ) MINS="60" ;; x|X) echo "Batal."; printf "ENTER..."; IFS= read -r _ || true; return 0 ;; *[!0-9]* ) echo "Harus angka bulat.";; *) break ;; esac
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
if [ "${BASH_SOURCE:-$0}" = "$0" ]; then add_user_vmess "$@"; fi
