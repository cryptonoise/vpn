#!/usr/bin/env bash
set -euo pipefail
export LC_ALL=C.UTF-8

VERSION="1.2.2"
NAME="SecureChain"

CONF_FILE="${CONF_FILE:-/root/.secure-chain.conf}"
REPORT_FILE="${REPORT_FILE:-/root/secure-chain-report.txt}"
LOG="${LOG:-/var/log/secure-chain.log}"
MARKER_FILE="${MARKER_FILE:-/root/.secure-chain.installed}"

TLS_DIR="${TLS_DIR:-/etc/secure-chain/tls}"
KEY_STORE_DIR="${KEY_STORE_DIR:-/root/.secure-chain}"
KEY_STORE_FILE="${KEY_STORE_FILE:-$KEY_STORE_DIR/relay-backend-key}"

PANEL_PORT_DEFAULT=999
INTERNAL_NAME="${INTERNAL_NAME:-backend.secure-chain.local}"
RELAY_WEBROOT="${RELAY_WEBROOT:-/var/www/secure-chain}"
BACKEND_WEBROOT="${BACKEND_WEBROOT:-/var/www/secure-chain-backend}"

RELAY_NGINX_AVAILABLE="/etc/nginx/sites-available/secure-chain-relay.conf"
RELAY_NGINX_TEMP_AVAILABLE="/etc/nginx/sites-available/secure-chain-temp.conf"
RELAY_NGINX_ENABLED="/etc/nginx/sites-enabled/secure-chain-relay.conf"
RELAY_NGINX_TEMP_ENABLED="/etc/nginx/sites-enabled/secure-chain-temp.conf"

if [ -t 1 ]; then
  B=$'\e[1m'; R=$'\e[0m'; DIM=$'\e[2m'
  GRN=$'\e[32m'; YLW=$'\e[33m'; RED=$'\e[31m'; BLU=$'\e[34m'; CYN=$'\e[36m'
else
  B=""; R=""; DIM=""; GRN=""; YLW=""; RED=""; BLU=""; CYN=""
fi

TMPD=""
STEP=0
TOTAL=18
MODE=""
RELAY_IP=""
BACKEND_IP=""
BACKEND_PORT=""
KEY_FILE=""
KEY_STORE_USED=0
DOMAIN=""
EMAIL=""
DNS_TARGET=""
CHANNEL_PATH=""
UUID=""
XU=""
XP=""
XW=""
INTERNAL_PORT=""
XRAY_PORT=""
PANEL_PORT=""
SSH_OPTS=()
UNINSTALL_ASSUME_YES=0
UNINSTALL_RM_XUI=""
UNINSTALL_RM_CERT=""

cleanup() {
  if [ -n "${TMPD:-}" ]; then
    rm -rf "$TMPD" 2>/dev/null || true
  fi
}
trap cleanup EXIT
trap 'echo; warn "прервано"; exit 130' INT TERM

log() {
  printf '[%s] %s\n' "$(date '+%F %T')" "$*" >> "$LOG" 2>/dev/null || true
}

ok()   { printf ' %s✔%s %s\n' "$GRN" "$R" "$*"; log "OK: $*"; }
info() { printf ' %s•%s %s\n' "$BLU" "$R" "$*"; log "INFO: $*"; }
warn() { printf ' %s▲%s %s\n' "$YLW" "$R" "$*"; log "WARN: $*"; }
fail() { printf ' %s✖%s %s\n' "$RED" "$R" "$*"; log "FAIL: $*"; }
die()  { fail "$*"; echo " ${DIM}Лог: $LOG${R}"; exit 1; }

rule() { printf '%s\n' "────────────────────────────────────────────────────────────"; }
thin() { printf '%s\n' "...................................................................."; }

kv() {
  printf ' %s%-18s%s %s\n' "$DIM" "$1" "$R" "$2"
}

section() {
  STEP=$((STEP + 1))
  echo
  printf '%s[%d/%d]%s %s%s%s\n' "$CYN" "$STEP" "$TOTAL" "$R" "$B" "$*" "$R"
  thin
}

banner() {
  clear 2>/dev/null || true
  rule
  printf ' %s%s%s\n' "$B" "$NAME" "$R"
  printf ' %sверсия %s%s\n' "$DIM" "$VERSION" "$R"
  rule
  echo " Цепочка: RELAY nginx + honeypot -> internal mTLS -> BACKEND 3x-ui/Xray VLESS WS"
  echo " Без rathole, без xhttp, без лишних режимов."
  echo
  if [ -r /dev/tty ]; then
    read -r -p " Нажмите Enter, чтобы начать." _ </dev/tty || true
  else
    read -r -p " Нажмите Enter, чтобы начать." _ || true
  fi
}

drain_tty() {
  if [ -r /dev/tty ]; then
    while IFS= read -r -t 0.05 -n 1 _j </dev/tty; do :; done
  fi
}

ask() {
  local __ref="$1" __prompt="$2" __default="${3:-}" __input=""
  drain_tty
  if [ -r /dev/tty ]; then
    read -r -p "$__prompt [$__default]: " __input </dev/tty || __input=""
  else
    read -r -p "$__prompt [$__default]: " __input || __input=""
  fi
  printf -v "$__ref" '%s' "${__input:-$__default}"
}

confirm() {
  local __prompt="$1" __default="${2:-y}" __ans=""
  drain_tty
  if [ -r /dev/tty ]; then
    read -r -p "$__prompt [${__default^^}]: " __ans </dev/tty || __ans="$__default"
  else
    read -r -p "$__prompt [${__default^^}]: " __ans || __ans="$__default"
  fi
  __ans="${__ans:-$__default}"
  [[ "$__ans" =~ ^[Yy] ]]
}

valid_ip() {
  local ip="$1"
  [[ "$ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || return 1
  local o
  IFS='.' read -ra octets <<< "$ip"
  [ "${#octets[@]}" -eq 4 ] || return 1
  for o in "${octets[@]}"; do
    [[ "$o" =~ ^[0-9]+$ ]] || return 1
    [ "$o" -le 255 ] || return 1
  done
  return 0
}

valid_port() {
  [[ "$1" =~ ^[0-9]+$ ]] && [ "$1" -ge 1 ] && [ "$1" -le 65535 ]
}

valid_dom() {
  [[ "$1" =~ ^[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?(\.[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?)+$ ]]
}

version_ge() {
  [ -n "$1" ] || return 1
  [ "$(printf '%s\n%s\n' "$1" "$2" | sort -V | head -n1)" = "$2" ]
}

sed_escape_dot() {
  printf '%s' "$1" | sed 's/\./\\./g'
}

rand_hex() {
  openssl rand -hex "${1:-8}"
}

new_uuid() {
  if [ -r /proc/sys/kernel/random/uuid ]; then
    cat /proc/sys/kernel/random/uuid
  else
    openssl rand -hex 16 | sed 's/\(........\)\(....\)\(....\)\(....\)\(............\)/\1-\2-\3-\4-\5/'
  fi
}

urlencode_path() {
  if command -v python3 >/dev/null 2>&1; then
    python3 -c 'import sys,urllib.parse; print(urllib.parse.quote(sys.argv[1], safe=""))' "$1" 2>/dev/null && return 0
  fi
  printf '%s' "$1" | sed 's|/|%2F|g'
}

ensure_tools() {
  local miss=()
  command -v curl >/dev/null 2>&1 || miss+=(curl)
  command -v dig >/dev/null 2>&1 || miss+=(dnsutils)
  { command -v ssh >/dev/null 2>&1 && command -v ssh-keygen >/dev/null 2>&1; } || miss+=(openssh-client)
  command -v openssl >/dev/null 2>&1 || miss+=(openssl)
  command -v python3 >/dev/null 2>&1 || miss+=(python3)
  command -v ss >/dev/null 2>&1 || miss+=(iproute2)
  command -v ufw >/dev/null 2>&1 || miss+=(ufw)

  if [ "${#miss[@]}" -eq 0 ]; then
    return 0
  fi

  info "устанавливаю на RELAY: ${miss[*]}"
  export DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=a
  apt-get -o DPkg::Lock::Timeout=300 update -y >>"$LOG" 2>&1 || return 1
  apt-get -o DPkg::Lock::Timeout=300 install -y "${miss[@]}" >>"$LOG" 2>&1 || return 1
}

detect_relay_ip() {
  local ip="" u
  for u in https://api.ipify.org https://ifconfig.me https://icanhazip.com; do
    ip=$(curl -4 -fsS --max-time 6 "$u" 2>/dev/null | tr -d '[:space:]' || true)
    if valid_ip "$ip"; then
      break
    fi
    ip=""
  done

  if [ -z "$ip" ]; then
    ip=$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{ for (i=1; i<=NF; i++) if ($i=="src") print $(i+1) }' | head -1 || true)
  fi

  printf '%s' "$ip"
}

ssh_ports() {
  {
    ss -tlnp 2>/dev/null | awk '/sshd/ { n=split($4,a,":"); print a[n] }'
    sshd -T 2>/dev/null | awk '/^port / { print $2 }'
    systemctl show ssh.socket -p Listen 2>/dev/null | sed -n 's/^Listen=.*:\([0-9][0-9]*\) (Stream)$/\1/p'
  } | grep -E '^[0-9]+$' | sort -un || true
}

remote_port_free() {
  local p="$1"
  ! bk "ss -tlnH 2>/dev/null | awk '{print \$4}' | grep -Eq '[:.]${p}\$'"
}

choose_remote_port() {
  local p
  for p in "$@"; do
    if remote_port_free "$p"; then
      printf '%s' "$p"
      return 0
    fi
  done
  return 1
}

bk() {
  [ "${#SSH_OPTS[@]}" -gt 0 ] || die "SSH к BACKEND не настроен"
  ssh -n "${SSH_OPTS[@]}" "root@$BACKEND_IP" bash -lc "$*"
}

remote_script() {
  local f="$1"
  shift
  [ "${#SSH_OPTS[@]}" -gt 0 ] || die "SSH к BACKEND не настроен"
  ssh "${SSH_OPTS[@]}" "root@$BACKEND_IP" bash -s -- "$@" < "$f"
}

key_is_valid() {
  [ -f "$1" ] && ssh-keygen -y -P "" -f "$1" >/dev/null 2>&1
}

try_backend_key() {
  local kf="$1"
  [ -n "${BACKEND_IP:-}" ] || return 1
  [ -n "${BACKEND_PORT:-}" ] || return 1
  key_is_valid "$kf" || return 1

  SSH_OPTS=(
    -i "$kf"
    -p "$BACKEND_PORT"
    -o IdentitiesOnly=yes
    -o StrictHostKeyChecking=accept-new
    -o ConnectTimeout=10
    -o BatchMode=yes
  )

  ssh -n "${SSH_OPTS[@]}" "root@$BACKEND_IP" true >/dev/null 2>&1
}

# ───────────────────────── ВВОД ПРИВАТНОГО КЛЮЧА (как в оригинале) ─────────────────────────
read_backend_key() {
  mkdir -p "$KEY_STORE_DIR" && chmod 700 "$KEY_STORE_DIR" || die "не удалось создать $KEY_STORE_DIR"

  local default_key="" f tries=0 line working

  if [ -f "$KEY_STORE_FILE" ]; then
    default_key="$KEY_STORE_FILE"
  else
    for f in /root/.ssh/id_ed25519 /root/.ssh/id_rsa /root/.ssh/id_ecdsa /root/.ssh/id_dsa; do
      if [ -f "$f" ]; then
        default_key="$f"
        break
      fi
    done
  fi

  while true; do
    tries=$((tries + 1))
    [ "$tries" -le 5 ] || die "ключ не получен за 5 попыток"

    working=""
    if [ -n "$default_key" ] && try_backend_key "$default_key"; then
      working="$default_key"
    fi

    echo "${B}?${R} Приватный ключ root для BACKEND: путь к файлу или вставьте ключ целиком ${DIM}(ввод скрыт)${R}"
    if [ -n "$working" ]; then
      echo " ${DIM}Enter — использовать рабочий ключ: $working${R}"
    elif [ -n "$default_key" ]; then
      echo " ${DIM}Enter — попробовать существующий файл: $default_key${R}"
    else
      echo " ${DIM}Подходящих ключей не найдено. Вставьте приватный ключ целиком, начиная с -----BEGIN ...${R}"
    fi

    IFS= read -r -s line
    echo
    line="${line//$'\r'/}"

    if [ -z "$line" ]; then
      if [ -n "$working" ]; then
        KEY_FILE="$working"
        if [ "$KEY_FILE" = "$KEY_STORE_FILE" ]; then
          KEY_STORE_USED=1
        else
          KEY_STORE_USED=0
        fi
        ok "используется ключ: $KEY_FILE"
        return 0
      elif [ -n "$default_key" ] && key_is_valid "$default_key"; then
        KEY_FILE="$default_key"
        if [ "$KEY_FILE" = "$KEY_STORE_FILE" ]; then
          KEY_STORE_USED=1
        else
          KEY_STORE_USED=0
        fi
        ok "используется ключ: $KEY_FILE"
        return 0
      else
        fail "ключ не указан"
        continue
      fi
    elif [[ "$line" == -BEGIN* ]]; then
      KEY_FILE="$TMPD/key"
      printf '%s\n' "$line" > "$KEY_FILE"
      while IFS= read -r -s line; do
        line="${line//$'\r'/}"
        printf '%s\n' "$line" >> "$KEY_FILE"
        [[ "$line" == -END* ]] && break
      done
      echo
      chmod 600 "$KEY_FILE"
    elif [ -f "$line" ]; then
      KEY_FILE="$line"
    else
      fail "файл не найден: $line"
      continue
    fi

    if ssh-keygen -y -P "" -f "$KEY_FILE" > "$TMPD/key.pub" 2>/dev/null; then
      ok "ключ принят"
      if [ "$KEY_FILE" = "$TMPD/key" ]; then
        mv -f "$KEY_FILE" "$KEY_STORE_FILE"
        chmod 600 "$KEY_STORE_FILE" || true
        KEY_FILE="$KEY_STORE_FILE"
        KEY_STORE_USED=1
        ok "приватный ключ сохранён: $KEY_FILE"
      else
        if [ "$KEY_FILE" = "$KEY_STORE_FILE" ]; then
          KEY_STORE_USED=1
        else
          KEY_STORE_USED=0
        fi
      fi
      return 0
    fi

    fail "ключ не читается (неверный формат или защищён паролем — такие не поддерживаются)"
    KEY_FILE=""
  done
}

ssh_connect() {
  local err np
  while true; do
    if [ -z "${KEY_FILE:-}" ]; then
      read_backend_key || die "не получен валидный SSH-ключ для BACKEND"
    fi

    SSH_OPTS=(
      -i "$KEY_FILE"
      -p "$BACKEND_PORT"
      -o IdentitiesOnly=yes
      -o StrictHostKeyChecking=accept-new
      -o ConnectTimeout=15
      -o BatchMode=yes
      -o ServerAliveInterval=15
      -o ServerAliveCountMax=4
    )

    if ssh -n "${SSH_OPTS[@]}" "root@$BACKEND_IP" true >/dev/null 2>"$TMPD/ssh.err"; then
      ok "SSH: root@$BACKEND_IP:$BACKEND_PORT"
      return 0
    fi

    err=$(cat "$TMPD/ssh.err" 2>/dev/null || true)

    if echo "$err" | grep -q 'REMOTE HOST IDENTIFICATION HAS CHANGED'; then
      warn "ключ хоста BACKEND изменился"
      if confirm "Удалить старую запись из known_hosts и продолжить?" y; then
        ssh-keygen -R "[$BACKEND_IP]:$BACKEND_PORT" >/dev/null 2>&1 || true
        ssh-keygen -R "$BACKEND_IP" >/dev/null 2>&1 || true
        continue
      else
        die "подключение отменено"
      fi
    fi

    if echo "$err" | grep -qi 'permission denied'; then
      fail "BACKEND не принял ключ. Проверьте, что публичная часть ключа есть в root@BACKEND:~/.ssh/authorized_keys"
      KEY_FILE=""
      read_backend_key || die "без валидного ключа к BACKEND продолжить нельзя"
      continue
    fi

    fail "SSH не удался: $(tail -n1 "$TMPD/ssh.err" 2>/dev/null || echo неизвестная ошибка)"
    ask np "SSH-порт BACKEND" "$BACKEND_PORT"
    if valid_port "$np"; then
      BACKEND_PORT="$np"
    else
      fail "неверный порт"
    fi

    KEY_FILE=""
    read_backend_key || die "без SSH к BACKEND продолжить нельзя"
  done
}

backend_os_check() {
  local bos
  bos=$(bk '. /etc/os-release; echo "$ID $VERSION_ID"' 2>>"$LOG" || true)

  case "$bos" in
    ubuntu\ *)
      local ver="${bos#ubuntu }"
      if version_ge "$ver" 22.04; then
        ok "ОС BACKEND: Ubuntu $ver"
      else
        die "BACKEND: нужна Ubuntu 22.04 или новее (найдена $ver)"
      fi
      ;;
    debian\ *)
      warn "ОС BACKEND: $bos (скрипт рассчитан на Ubuntu 22.04+)"
      ;;
    *)
      warn "ОС BACKEND не определена: ${bos:-?}"
      ;;
  esac
}

nginx_ipv6_enabled() {
  if [ -e /proc/net/if_inet6 ] && [ "$(cat /proc/sys/net/ipv6/conf/all/disable_ipv6 2>/dev/null || echo 1)" = 0 ]; then
    echo 1
  else
    echo 0
  fi
}

dns_collect() {
  local d
  for d in 8.8.8.8 1.1.1.1 77.88.8.8; do
    dig +short +time=3 +tries=1 A "$DOMAIN" @"$d" 2>/dev/null || true
  done
  getent ahostsv4 "$DOMAIN" 2>/dev/null | awk '{ print $1 }' || true
}

dns_check() {
  local all v6 tgt="${DNS_TARGET:-$RELAY_IP}"
  all=$(dns_collect 2>/dev/null | grep -E '^[0-9]{1,3}(\.[0-9]{1,3}){3}$' | sort -u | tr '\n' ' ' || true)
  all="${all% }"
  v6=$(dig +short +time=3 +tries=1 AAAA "$DOMAIN" @8.8.8.8 2>/dev/null | grep ':' | head -1 || true)

  if [ "$all" = "$tgt" ] && [ -z "$v6" ]; then
    ok "DNS: $DOMAIN -> $all"
    return 0
  fi

  warn "DNS не идеален: A='${all:-нет}', AAAA='${v6:-нет}', ожидается IPv4='$tgt'"
  warn "Если сертификат Let's Encrypt не выпустится, поправьте A-запись и уберите AAAA."
  return 1
}

tune_relay() {
  sysctl -w net.core.default_qdisc=fq >>"$LOG" 2>&1 || true
  sysctl -w net.ipv4.tcp_congestion_control=bbr >>"$LOG" 2>&1 || true
  sysctl -w net.ipv4.tcp_mtu_probing=1 >>"$LOG" 2>&1 || true
  sysctl -w net.core.rmem_max=16777216 >>"$LOG" 2>&1 || true
  sysctl -w net.core.wmem_max=16777216 >>"$LOG" 2>&1 || true
  sysctl -w net.ipv4.tcp_rmem="4096 87380 16777216" >>"$LOG" 2>&1 || true
  sysctl -w net.ipv4.tcp_wmem="4096 65536 16777216" >>"$LOG" 2>&1 || true
  sysctl -w net.ipv4.tcp_slow_start_after_idle=0 >>"$LOG" 2>&1 || true
  return 0
}

generate_internal_tls() {
  if [ -f "$TLS_DIR/ca.pem" ] &&
     [ -f "$TLS_DIR/backend.crt" ] &&
     [ -f "$TLS_DIR/backend.key" ] &&
     [ -f "$TLS_DIR/relay-client.crt" ] &&
     [ -f "$TLS_DIR/relay-client.key" ] &&
     openssl x509 -in "$TLS_DIR/backend.crt" -noout -checkend 86400 2>/dev/null &&
     openssl x509 -in "$TLS_DIR/backend.crt" -noout -ext subjectAltName 2>/dev/null | grep -q "DNS:$INTERNAL_NAME"; then
    ok "внутренний mTLS CA/сертификаты уже существуют"
    return 0
  fi

  mkdir -p "$TLS_DIR" && chmod 700 "$TLS_DIR" || return 1

  openssl genrsa -out "$TLS_DIR/ca.key" 4096 >>"$LOG" 2>&1 || return 1
  openssl req -x509 -new -nodes -key "$TLS_DIR/ca.key" -sha256 -days 3650 \
    -out "$TLS_DIR/ca.pem" -subj "/CN=Secure Chain Internal CA" >>"$LOG" 2>&1 || return 1

  openssl genrsa -out "$TLS_DIR/backend.key" 2048 >>"$LOG" 2>&1 || return 1
  openssl req -new -key "$TLS_DIR/backend.key" -out "$TLS_DIR/backend.csr" \
    -subj "/CN=$INTERNAL_NAME" >>"$LOG" 2>&1 || return 1

  cat > "$TLS_DIR/backend.ext" <<EOF
subjectAltName=DNS:$INTERNAL_NAME
extendedKeyUsage=serverAuth
EOF

  openssl x509 -req -in "$TLS_DIR/backend.csr" -CA "$TLS_DIR/ca.pem" -CAkey "$TLS_DIR/ca.key" \
    -CAcreateserial -out "$TLS_DIR/backend.crt" -days 3650 -sha256 \
    -extfile "$TLS_DIR/backend.ext" >>"$LOG" 2>&1 || return 1

  openssl genrsa -out "$TLS_DIR/relay-client.key" 2048 >>"$LOG" 2>&1 || return 1
  openssl req -new -key "$TLS_DIR/relay-client.key" -out "$TLS_DIR/relay-client.csr" \
    -subj "/CN=relay.secure-chain.local" >>"$LOG" 2>&1 || return 1

  cat > "$TLS_DIR/client.ext" <<EOF
subjectAltName=DNS:relay.secure-chain.local
extendedKeyUsage=clientAuth
EOF

  openssl x509 -req -in "$TLS_DIR/relay-client.csr" -CA "$TLS_DIR/ca.pem" -CAkey "$TLS_DIR/ca.key" \
    -CAcreateserial -out "$TLS_DIR/relay-client.crt" -days 3650 -sha256 \
    -extfile "$TLS_DIR/client.ext" >>"$LOG" 2>&1 || return 1

  chmod 600 "$TLS_DIR"/* || return 1
  rm -f "$TLS_DIR"/*.csr "$TLS_DIR"/*.srl "$TLS_DIR"/*.ext

  ok "сгенерирован внутренний mTLS CA/сертификаты"
}

deploy_backend_tls() {
  ssh -n "${SSH_OPTS[@]}" "root@$BACKEND_IP" "mkdir -p /etc/secure-chain/tls && chmod 700 /etc/secure-chain/tls" >>"$LOG" 2>&1 || return 1
  ssh "${SSH_OPTS[@]}" "root@$BACKEND_IP" "cat > /etc/secure-chain/tls/ca.pem" < "$TLS_DIR/ca.pem" >>"$LOG" 2>&1 || return 1
  ssh "${SSH_OPTS[@]}" "root@$BACKEND_IP" "cat > /etc/secure-chain/tls/server.crt" < "$TLS_DIR/backend.crt" >>"$LOG" 2>&1 || return 1
  ssh "${SSH_OPTS[@]}" "root@$BACKEND_IP" "cat > /etc/secure-chain/tls/server.key" < "$TLS_DIR/backend.key" >>"$LOG" 2>&1 || return 1
  ssh -n "${SSH_OPTS[@]}" "root@$BACKEND_IP" "chmod 600 /etc/secure-chain/tls/*" >>"$LOG" 2>&1 || return 1
  ok "mTLS сертификаты доставлены на BACKEND"
}

relay_packages() {
  export DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=a
  apt-get -o DPkg::Lock::Timeout=300 update -y >>"$LOG" 2>&1 || return 1
  apt-get -o DPkg::Lock::Timeout=300 install -y nginx certbot python3-certbot-nginx ufw openssl iproute2 dnsutils python3 curl >>"$LOG" 2>&1 || return 1
  systemctl enable nginx >/dev/null 2>&1 || true
  systemctl disable --now rathole >/dev/null 2>&1 || true
  ok "пакеты RELAY установлены, старый rathole отключён, если был"
}

relay_firewall() {
  local ports p
  ports=$(ssh_ports)
  [ -n "$ports" ] || die "не найден SSH-порт RELAY, firewall не включаю, чтобы не потерять доступ"

  for p in $ports; do
    ufw allow "$p/tcp" >>"$LOG" 2>&1 || return 1
  done

  ufw allow 80/tcp >>"$LOG" 2>&1 || return 1
  ufw allow 443/tcp >>"$LOG" 2>&1 || return 1

  for r in 2333/tcp 8443/tcp 8443/udp; do
    ufw delete allow "$r" >/dev/null 2>&1 || true
  done

  ufw --force enable >/dev/null || return 1
  ufw --force reload >/dev/null 2>&1 || true
  ok "firewall RELAY: SSH + 80/443, старые rathole-порты удалены"
}

relay_honeypot() {
  mkdir -p "$RELAY_WEBROOT" /var/www/certbot || return 1
  local rnd
  rnd=$(openssl rand -hex 4)

  cat > "$RELAY_WEBROOT/index.html" <<EOF
<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Status Page $rnd</title>
<style>
body{font-family:system-ui,-apple-system,Segoe UI,Roboto,Arial,sans-serif;margin:0;background:#f6f7f9;color:#111}
header{background:#fff;border-bottom:1px solid #ddd;padding:18px 24px}
main{max-width:900px;margin:32px auto;padding:0 20px}
.card{background:#fff;border:1px solid #e5e7eb;border-radius:12px;padding:20px;margin-bottom:16px}
.muted{color:#666}
code{background:#eef2ff;padding:2px 6px;border-radius:6px}
</style>
</head>
<body>
<header><strong>Service Status</strong></header>
<main>
<div class="card"><h1>All systems operational</h1><p class="muted">Last check: <code>$rnd</code></p></div>
<div class="card"><h2>API</h2><p>Operational</p></div>
<div class="card"><h2>Web</h2><p>Operational</p></div>
<div class="card"><h2>CDN</h2><p>Operational</p></div>
</main>
</body>
</html>
EOF

  cat > "$RELAY_WEBROOT/404.html" <<EOF
<!doctype html>
<html><head><meta charset="utf-8"><title>404</title></head>
<body style="font-family:system-ui;margin:40px"><h1>404 Not Found</h1><p>The requested resource is not available.</p></body></html>
EOF

  ok "honeypot RELAY создан: $RELAY_WEBROOT"
}

relay_temp_nginx() {
  relay_honeypot || return 1

  local v6 l6_80=""
  v6=$(nginx_ipv6_enabled)
  [ "$v6" = 1 ] && l6_80="listen [::]:80;"

  cat > "$RELAY_NGINX_TEMP_AVAILABLE" <<EOF
server {
    listen 80;
    $l6_80
    server_name $DOMAIN;
    root $RELAY_WEBROOT;
    index index.html;

    location ^~ /.well-known/acme-challenge/ {
        root /var/www/certbot;
    }

    location / {
        try_files \$uri \$uri/ =404;
    }
}
EOF

  rm -f /etc/nginx/sites-enabled/*
  ln -sf "$RELAY_NGINX_TEMP_AVAILABLE" "$RELAY_NGINX_TEMP_ENABLED"
  nginx -t >>"$LOG" 2>&1 || return 1
  systemctl reload nginx >>"$LOG" 2>&1 || return 1
  ok "временный nginx RELAY для ACME активен"
}

relay_cert() {
  if [ -f "/etc/letsencrypt/live/$DOMAIN/fullchain.pem" ] &&
     [ -f "/etc/letsencrypt/live/$DOMAIN/privkey.pem" ]; then
    ok "сертификат Let's Encrypt уже существует для $DOMAIN"
    return 0
  fi

  relay_temp_nginx || return 1

  certbot certonly --webroot -w /var/www/certbot -d "$DOMAIN" \
    --non-interactive --agree-tos -m "$EMAIL" \
    --keep-until-expiring --deploy-hook "systemctl reload nginx" >>"$LOG" 2>&1 || return 1

  ok "выпущен сертификат для $DOMAIN"
}

relay_final_nginx() {
  local v6 l6_80=""
  v6=$(nginx_ipv6_enabled)
  [ "$v6" = 1 ] && l6_80="listen [::]:80;"

  local nginx_ver listen443 http2_directive=""
  nginx_ver="$(nginx -v 2>&1 | sed 's/.*nginx\///; s/[^0-9.].*//')"

  if version_ge "$nginx_ver" 1.25.1; then
    listen443="listen 443 ssl;"
    http2_directive="http2 on;"
  else
    listen443="listen 443 ssl http2;"
  fi

  if [ "$v6" = 1 ]; then
    if version_ge "$nginx_ver" 1.25.1; then
      listen443+="
listen [::]:443 ssl;"
    else
      listen443+="
listen [::]:443 ssl http2;"
    fi
  fi

  cat > "$RELAY_NGINX_AVAILABLE" <<EOF
limit_req_zone \$binary_remote_addr zone=sc_ws_limit_relay:10m rate=10r/s;

map \$http_upgrade \$connection_upgrade {
    default upgrade;
    '' close;
}

map \$http_upgrade \$sc_upgrade_ok {
    default 0;
    "~*^(websocket|http-upgrade)$" 1;
}

server {
    listen 80;
    $l6_80
    server_name $DOMAIN;

    location ^~ /.well-known/acme-challenge/ {
        root /var/www/certbot;
    }

    location / {
        return 301 https://\$host\$request_uri;
    }
}

server {
    $listen443
    $http2_directive
    server_name $DOMAIN;

    ssl_certificate /etc/letsencrypt/live/$DOMAIN/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/$DOMAIN/privkey.pem;
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_ciphers HIGH:!aNULL:!MD5;
    ssl_prefer_server_ciphers on;
    ssl_session_cache shared:SCRELAYSSL:10m;
    ssl_session_timeout 10m;
    ssl_session_tickets off;
    server_tokens off;

    add_header X-Content-Type-Options "nosniff" always;
    add_header X-Frame-Options "SAMEORIGIN" always;
    add_header Referrer-Policy "strict-origin-when-cross-origin" always;
    add_header Strict-Transport-Security "max-age=63072000; includeSubDomains" always;

    root $RELAY_WEBROOT;
    index index.html;
    error_page 404 /404.html;
    location = /404.html { internal; }

    location ~ /\.(?!well-known) {
        return 404;
    }

    location = $CHANNEL_PATH {
        access_log off;
        limit_req zone=sc_ws_limit_relay burst=20 nodelay;

        if (\$sc_upgrade_ok = 0) {
            return 404;
        }

        proxy_pass https://$INTERNAL_NAME:$INTERNAL_PORT;
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection \$connection_upgrade;
        proxy_set_header Host $DOMAIN;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto https;

        proxy_ssl_certificate $TLS_DIR/relay-client.crt;
        proxy_ssl_certificate_key $TLS_DIR/relay-client.key;
        proxy_ssl_trusted_certificate $TLS_DIR/ca.pem;
        proxy_ssl_verify on;
        proxy_ssl_name $INTERNAL_NAME;
        proxy_ssl_server_name on;

        proxy_buffering off;
        proxy_request_buffering off;
        proxy_read_timeout 300s;
        proxy_send_timeout 300s;
    }

    location / {
        try_files \$uri \$uri/ =404;
    }
}
EOF

  rm -f /etc/nginx/sites-enabled/*
  ln -sf "$RELAY_NGINX_AVAILABLE" "$RELAY_NGINX_ENABLED"
  nginx -t >>"$LOG" 2>&1 || return 1
  systemctl reload nginx >>"$LOG" 2>&1 || return 1
  systemctl enable --now certbot.timer >/dev/null 2>&1 || true

  ok "финальный nginx RELAY применён"
}

update_relay_hosts() {
  local re
  re=$(sed_escape_dot "$INTERNAL_NAME")
  sed -i "/[[:space:]]${re}\$/d" /etc/hosts || return 1
  echo "$BACKEND_IP $INTERNAL_NAME" >> /etc/hosts || return 1
  ok "/etc/hosts RELAY: $INTERNAL_NAME -> $BACKEND_IP"
}

install_relay_helper() {
  local internal_re
  internal_re=$(sed_escape_dot "$INTERNAL_NAME")

  cat > /usr/local/bin/secure-chain-set-backend <<EOF
#!/bin/bash
set -e
NEW="\$1"
[ -z "\$NEW" ] && { echo "usage: secure-chain-set-backend НОВЫЙ_IP_BACKEND"; exit 1; }
sed -i "/[[:space:]]${internal_re}\$/d" /etc/hosts
echo "\$NEW ${INTERNAL_NAME}" >> /etc/hosts
systemctl reload nginx
echo "Secure Chain backend updated: \$NEW"
EOF

  chmod +x /usr/local/bin/secure-chain-set-backend
  ok "установлена команда secure-chain-set-backend"
}

post_checks() {
  local code

  code=$(curl -s -o /dev/null --max-time 10 -w '%{http_code}' "https://$DOMAIN/" 2>/dev/null || true)
  if [ "$code" = "200" ]; then
    ok "honeypot RELAY отвечает HTTP 200"
  else
    warn "honeypot RELAY вернул HTTP ${code:-000}"
  fi

  code=$(curl -s -o /dev/null --max-time 10 -w '%{http_code}' "https://$DOMAIN$CHANNEL_PATH" 2>/dev/null || true)
  if [ "$code" = "404" ]; then
    ok "канал скрыт без WebSocket/HTTPUpgrade upgrade: HTTP 404"
  else
    warn "канал без upgrade вернул HTTP ${code:-000}, ожидался 404"
  fi
}

make_remote_scripts() {
  local D="$TMPD"

  cat > "$D/f2b-ignore.sh" <<'EOF'
IP="$1"
J=/etc/fail2ban/jail.local
[ -f "$J" ] || exit 0
if grep -q '^ignoreip' "$J"; then
  grep -q "$IP" "$J" || sed -i "s|^ignoreip.*|& $IP|" "$J"
else
  sed -i "/^\[sshd\]/a ignoreip = 127.0.0.1/8 ::1 $IP" "$J"
fi
systemctl restart fail2ban >/dev/null 2>&1 || true
exit 0
EOF

  cat > "$D/be-tune.sh" <<'EOF'
set -e
sysctl -w net.core.default_qdisc=fq >/dev/null 2>&1 || true
sysctl -w net.ipv4.tcp_congestion_control=bbr >/dev/null 2>&1 || true
sysctl -w net.ipv4.tcp_mtu_probing=1 >/dev/null 2>&1 || true
sysctl -w net.core.rmem_max=16777216 >/dev/null 2>&1 || true
sysctl -w net.core.wmem_max=16777216 >/dev/null 2>&1 || true
sysctl -w net.ipv4.tcp_rmem="4096 87380 16777216" >/dev/null 2>&1 || true
sysctl -w net.ipv4.tcp_wmem="4096 65536 16777216" >/dev/null 2>&1 || true
sysctl -w net.ipv4.tcp_slow_start_after_idle=0 >/dev/null 2>&1 || true
EOF

  cat > "$D/be-pkgs.sh" <<'EOF'
set -e
export DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=a
apt-get -o DPkg::Lock::Timeout=300 update -y
apt-get -o DPkg::Lock::Timeout=300 upgrade -y
apt-get -o DPkg::Lock::Timeout=300 install -y nginx ufw openssl python3 curl dnsutils iproute2 sqlite3
systemctl enable nginx >/dev/null 2>&1 || true
EOF

  cat > "$D/be-xui.sh" <<'EOF'
set -e
PANEL_PORT="$1"
XU="$2"
XP="$3"
XW="$4"

if [ ! -x /usr/local/x-ui/x-ui ]; then
  curl -fsSL https://raw.githubusercontent.com/mhsanaei/3x-ui/master/install.sh -o /tmp/3xui-install.sh
  XUI_NONINTERACTIVE=1 XUI_DB_TYPE=sqlite XUI_SSL_MODE=none XUI_PANEL_PORT="$PANEL_PORT" bash /tmp/3xui-install.sh </dev/null
fi

if [ ! -x /usr/local/x-ui/x-ui ]; then
  echo "x-ui binary not found" >&2
  exit 1
fi

/usr/local/x-ui/x-ui setting -listenIP 127.0.0.1 || true
/usr/local/x-ui/x-ui setting -port "$PANEL_PORT" || true
/usr/local/x-ui/x-ui setting -username "$XU" || true
/usr/local/x-ui/x-ui setting -password "$XP" || true
/usr/local/x-ui/x-ui setting -webBasePath "$XW" || true

systemctl daemon-reload || true
systemctl enable x-ui >/dev/null 2>&1 || true
systemctl restart x-ui
sleep 3

if ! systemctl is-active --quiet x-ui; then
  echo "x-ui service is not active" >&2
  exit 1
fi

if ! ss -tlnH | grep -q "127.0.0.1:$PANEL_PORT"; then
  echo "x-ui is not listening on 127.0.0.1:$PANEL_PORT" >&2
  exit 1
fi
EOF

  cat > "$D/be-nginx.sh" <<'EOF'
set -e
RELAY_DOMAIN="$1"
INTERNAL_NAME="$2"
INTERNAL_PORT="$3"
XRAY_PORT="$4"
CHANNEL_PATH="$5"
WEBROOT="$6"
TLS_DIR="$7"
NGINX_CONF="/etc/nginx/sites-available/secure-chain-backend.conf"

mkdir -p "$WEBROOT"

cat > "$WEBROOT/index.html" <<'HTML'
<!doctype html>
<html><head><meta charset="utf-8"><title>Internal Service</title></head>
<body style="font-family:system-ui;margin:40px"><h1>Internal endpoint</h1><p>This host is not intended for public access.</p></body></html>
HTML

cat > "$WEBROOT/404.html" <<'HTML'
<!doctype html>
<html><head><meta charset="utf-8"><title>404</title></head>
<body style="font-family:system-ui;margin:40px"><h1>404 Not Found</h1></body></html>
HTML

V6=0
if [ -e /proc/net/if_inet6 ] && [ "$(cat /proc/sys/net/ipv6/conf/all/disable_ipv6 2>/dev/null || echo 1)" = 0 ]; then
  V6=1
fi

NGINX_VER="$(nginx -v 2>&1 | sed 's/.*nginx\///; s/[^0-9.].*//')"
HTTP2=""
if [ -n "$NGINX_VER" ] && [ "$(printf '%s\n%s\n' "$NGINX_VER" "1.25.1" | sort -V | head -n1)" = "1.25.1" ]; then
  LISTEN_SSL="listen $INTERNAL_PORT ssl;"
  HTTP2="http2 on;"
else
  LISTEN_SSL="listen $INTERNAL_PORT ssl http2;"
fi

if [ "$V6" = 1 ]; then
  if [ -n "$HTTP2" ]; then
    LISTEN_SSL="$LISTEN_SSL
listen [::]:$INTERNAL_PORT ssl;"
  else
    LISTEN_SSL="$LISTEN_SSL
listen [::]:$INTERNAL_PORT ssl http2;"
  fi
fi

cat > "$NGINX_CONF" <<EOT
limit_req_zone \$binary_remote_addr zone=sc_ws_limit_backend:10m rate=10r/s;

map \$http_upgrade \$connection_upgrade {
    default upgrade;
    '' close;
}

map \$http_upgrade \$sc_upgrade_ok {
    default 0;
    "~*^(websocket|http-upgrade)$" 1;
}

server {
    $LISTEN_SSL
    $HTTP2
    server_name $INTERNAL_NAME;

    ssl_certificate $TLS_DIR/server.crt;
    ssl_certificate_key $TLS_DIR/server.key;
    ssl_client_certificate $TLS_DIR/ca.pem;
    ssl_verify_client on;
    ssl_protocols TLSv1.3;
    ssl_prefer_server_ciphers on;
    ssl_session_cache shared:SCBACKENDSSL:10m;
    ssl_session_timeout 10m;
    ssl_session_tickets off;
    server_tokens off;

    root $WEBROOT;
    index index.html;
    error_page 404 /404.html;
    location = /404.html { internal; }

    location ~ /\.(?!well-known) {
        return 404;
    }

    location = $CHANNEL_PATH {
        access_log off;
        limit_req zone=sc_ws_limit_backend burst=20 nodelay;

        if (\$sc_upgrade_ok = 0) {
            return 404;
        }

        proxy_pass http://127.0.0.1:$XRAY_PORT;
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection \$connection_upgrade;
        proxy_set_header Host $RELAY_DOMAIN;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto https;

        proxy_buffering off;
        proxy_request_buffering off;
        proxy_read_timeout 300s;
        proxy_send_timeout 300s;
    }

    location / {
        try_files \$uri \$uri/ =404;
    }
}
EOT

ln -sf "$NGINX_CONF" "/etc/nginx/sites-enabled/secure-chain-backend.conf"
rm -f /etc/nginx/sites-enabled/default 2>/dev/null || true
nginx -t
systemctl reload nginx
EOF

  cat > "$D/be-fw.sh" <<'EOF'
set -e
RELAY="$1"
PORT="$2"

ports=$( {
  ss -tlnp 2>/dev/null | awk '/sshd/ { n=split($4,a,":"); print a[n] }'
  sshd -T 2>/dev/null | awk '/^port / { print $2 }'
  systemctl show ssh.socket -p Listen 2>/dev/null | sed -n 's/^Listen=.*:\([0-9][0-9]*\) (Stream)$/\1/p'
} | grep -E '^[0-9]+$' | sort -un || true )

[ -n "$ports" ] || { echo "SSH port not found on BACKEND" >&2; exit 1; }

for p in $ports; do
  ufw allow "$p/tcp"
done

ufw delete allow from any to any port "$PORT" proto tcp >/dev/null 2>&1 || true
ufw allow from "$RELAY" to any port "$PORT" proto tcp

for r in 80/tcp 443/tcp 8443/tcp 8443/udp 2333/tcp; do
  ufw delete allow "$r" >/dev/null 2>&1 || true
done

ufw --force enable >/dev/null
ufw --force reload >/dev/null 2>&1 || true
EOF

  cat > "$D/be-api.sh" <<'EOF'
set -e
PANEL_PORT="$1"
BASE_PATH="${2#/}"
BASE_PATH="${BASE_PATH%/}"
XU="$3"
XP="$4"
UUID="$5"
XRAY_PORT="$6"
CHANNEL_PATH="$7"
RELAY_DOMAIN="$8"

BASE="http://127.0.0.1:$PANEL_PORT/$BASE_PATH"
COOKIE="$(mktemp)"
trap 'rm -f "$COOKIE"' EXIT

SETTINGS="{\"clients\":[{\"id\":\"$UUID\",\"email\":\"secure-chain\",\"enable\":true}],\"decryption\":\"none\"}"
STREAM="{\"network\":\"ws\",\"security\":\"none\",\"wsSettings\":{\"path\":\"$CHANNEL_PATH\",\"host\":\"$RELAY_DOMAIN\"}}"
SNIFFING="{\"enabled\":true,\"destOverride\":[\"http\",\"tls\"]}"

RESP_LOGIN=$(curl -sS -c "$COOKIE" -X POST "$BASE/login" \
  -H "X-Requested-With: XMLHttpRequest" \
  --data-urlencode "username=$XU" \
  --data-urlencode "password=$XP" 2>&1 || true)

if ! echo "$RESP_LOGIN" | grep -Eq '"success"[[:space:]]*:[[:space:]]*true'; then
  echo "3x-ui login failed: $RESP_LOGIN" >&2
  exit 1
fi

RESP_ADD=$(curl -sS -b "$COOKIE" -X POST "$BASE/panel/api/inbounds/add" \
  -H "X-Requested-With: XMLHttpRequest" \
  --data-urlencode "remark=SecureChain" \
  --data-urlencode "enable=true" \
  --data-urlencode "expiryTime=0" \
  --data-urlencode "up=0" \
  --data-urlencode "down=0" \
  --data-urlencode "total=0" \
  --data-urlencode "listen=127.0.0.1" \
  --data-urlencode "port=$XRAY_PORT" \
  --data-urlencode "protocol=vless" \
  --data-urlencode "settings=$SETTINGS" \
  --data-urlencode "streamSettings=$STREAM" \
  --data-urlencode "sniffing=$SNIFFING" \
  --data-urlencode "allocate={}" \
  --data-urlencode "tag=sc-vless-$(date +%s)" \
  --data-urlencode "domain=" \
  --data-urlencode "tgId=" \
  --data-urlencode "subId=sc$(date +%s)" 2>&1 || true)

if echo "$RESP_ADD" | grep -Eq '"success"[[:space:]]*:[[:space:]]*true'; then
  exit 0
fi

if echo "$RESP_ADD" | grep -qi 'already exists'; then
  exit 0
fi

echo "3x-ui add inbound failed: $RESP_ADD" >&2
exit 1
EOF

  cat > "$D/be-uninstall.sh" <<'EOF'
set -e
RELAY="$1"
PORT="$2"
RM_XUI="$3"

rm -f /etc/nginx/sites-enabled/secure-chain-backend.conf /etc/nginx/sites-available/secure-chain-backend.conf
rm -rf /var/www/secure-chain-backend
rm -rf /etc/secure-chain

ufw delete allow from "$RELAY" to any port "$PORT" proto tcp >/dev/null 2>&1 || true
ufw --force reload >/dev/null 2>&1 || true

nginx -t >/dev/null 2>&1 && systemctl reload nginx >/dev/null 2>&1 || true

if [ "$RM_XUI" = "1" ]; then
  systemctl stop x-ui >/dev/null 2>&1 || true
  systemctl disable x-ui >/dev/null 2>&1 || true
  rm -f /etc/systemd/system/x-ui.service >/dev/null 2>&1 || true
  systemctl daemon-reload >/dev/null 2>&1 || true
  rm -rf /usr/local/x-ui /etc/x-ui >/dev/null 2>&1 || true
fi
EOF
}

marker_get() {
  [ -f "$MARKER_FILE" ] || return 0
  sed -n "s/^$1=//p" "$MARKER_FILE" 2>/dev/null | head -1 || true
}

write_marker() {
  local status="$1"
  mkdir -p "$(dirname "$MARKER_FILE")" 2>/dev/null || true
  cat > "$MARKER_FILE" <<EOF
INSTALL_KIND=secure-chain
INSTALLED_AT=$(date '+%F %T')
STATUS=$status
VERSION=$VERSION
RELAY_IP=${RELAY_IP:-}
BACKEND_IP=${BACKEND_IP:-}
BACKEND_PORT=${BACKEND_PORT:-}
KEY_FILE=${KEY_FILE:-}
KEY_STORE_USED=${KEY_STORE_USED:-0}
DOMAIN=${DOMAIN:-}
EMAIL=${EMAIL:-}
CHANNEL_PATH=${CHANNEL_PATH:-}
UUID=${UUID:-}
INTERNAL_NAME=${INTERNAL_NAME:-}
INTERNAL_PORT=${INTERNAL_PORT:-}
XRAY_PORT=${XRAY_PORT:-}
PANEL_PORT=${PANEL_PORT:-}
XU=${XU:-}
XP=${XP:-}
XW=${XW:-}
EOF
  chmod 600 "$MARKER_FILE" || true
}

save_conf() {
  : > "$CONF_FILE"
  chmod 600 "$CONF_FILE" || true
  cat > "$CONF_FILE" <<EOF
RELAY_IP=${RELAY_IP:-}
BACKEND_IP=${BACKEND_IP:-}
BACKEND_PORT=${BACKEND_PORT:-}
KEY_FILE=${KEY_FILE:-}
KEY_STORE_USED=${KEY_STORE_USED:-0}
DOMAIN=${DOMAIN:-}
EMAIL=${EMAIL:-}
CHANNEL_PATH=${CHANNEL_PATH:-}
UUID=${UUID:-}
INTERNAL_NAME=${INTERNAL_NAME:-}
INTERNAL_PORT=${INTERNAL_PORT:-}
XRAY_PORT=${XRAY_PORT:-}
PANEL_PORT=${PANEL_PORT:-}
XU=${XU:-}
XP=${XP:-}
XW=${XW:-}
EOF
  chmod 600 "$CONF_FILE" || true
}

load_conf() {
  [ -f "$CONF_FILE" ] || return 0
  set -a
  # shellcheck disable=SC1090
  . "$CONF_FILE" 2>/dev/null || true
  set +a
}

load_marker() {
  [ -f "$MARKER_FILE" ] || return 0
  set -a
  # shellcheck disable=SC1090
  . "$MARKER_FILE" 2>/dev/null || true
  set +a
}

check_reinstall() {
  if [ -f "$MARKER_FILE" ]; then
    load_marker
    warn "найдена метка установки: $(marker_get INSTALLED_AT), статус: $(marker_get STATUS)"
    if confirm "Переустановить Secure Chain? Сначала будет выполнен откат." n; then
      UNINSTALL_ASSUME_YES=1
      UNINSTALL_RM_XUI=1
      UNINSTALL_RM_CERT=0
      do_uninstall || true
    else
      echo " Отменено."
      exit 0
    fi
  fi
}

do_uninstall() {
  load_marker

  if [ ! -f "$MARKER_FILE" ]; then
    warn "метка установки не найдена"
    return 1
  fi

  STEP=0
  TOTAL=4

  if [ "${UNINSTALL_ASSUME_YES:-0}" != 1 ]; then
    confirm "Удалить установку Secure Chain?" n || { echo " Отменено."; return 1; }
  fi

  if [ -z "${UNINSTALL_RM_XUI:-}" ]; then
    if confirm "Удалить на BACKEND 3x-ui и внутренние настройки?" y; then
      UNINSTALL_RM_XUI=1
    else
      UNINSTALL_RM_XUI=0
    fi
  fi

  if [ -z "${UNINSTALL_RM_CERT:-}" ]; then
    if confirm "Удалить сертификат Let's Encrypt на RELAY для ${DOMAIN:-?}?" n; then
      UNINSTALL_RM_CERT=1
    else
      UNINSTALL_RM_CERT=0
    fi
  fi

  section "RELAY: удаление"

  rm -f "$RELAY_NGINX_ENABLED" "$RELAY_NGINX_AVAILABLE" "$RELAY_NGINX_TEMP_ENABLED" "$RELAY_NGINX_TEMP_AVAILABLE" 2>/dev/null || true
  rm -rf "$RELAY_WEBROOT" 2>/dev/null || true
  rm -rf "$TLS_DIR" 2>/dev/null || true
  rm -f /usr/local/bin/secure-chain-set-backend 2>/dev/null || true

  if [ -n "${INTERNAL_NAME:-}" ]; then
    local re
    re=$(sed_escape_dot "$INTERNAL_NAME")
    sed -i "/[[:space:]]${re}\$/d" /etc/hosts 2>/dev/null || true
  fi

  ufw delete allow 80/tcp >/dev/null 2>&1 || true
  ufw delete allow 443/tcp >/dev/null 2>&1 || true
  ufw delete allow 2333/tcp >/dev/null 2>&1 || true
  ufw delete allow 8443/tcp >/dev/null 2>&1 || true
  ufw delete allow 8443/udp >/dev/null 2>&1 || true
  ufw --force reload >/dev/null 2>&1 || true

  if command -v nginx >/dev/null 2>&1; then
    nginx -t >/dev/null 2>&1 && systemctl reload nginx >/dev/null 2>&1 || true
  fi

  if [ "${UNINSTALL_RM_CERT:-0}" = 1 ] && [ -n "${DOMAIN:-}" ]; then
    certbot delete --cert-name "$DOMAIN" --non-interactive >/dev/null 2>&1 || true
    ok "сертификат $DOMAIN удалён, если существовал"
  fi

  if [ "${KEY_STORE_USED:-0}" = 1 ] && [ "${KEY_FILE:-}" = "$KEY_STORE_FILE" ]; then
    rm -f "$KEY_STORE_FILE" 2>/dev/null || true
    rmdir "$KEY_STORE_DIR" 2>/dev/null || true
    ok "сохранённый приватный ключ удалён"
  fi

  ok "RELAY: настройки Secure Chain удалены"

  section "BACKEND: удаление"

  local backend_ok=0
  if [ -n "${BACKEND_IP:-}" ] && [ -n "${KEY_FILE:-}" ] && [ -f "$KEY_FILE" ]; then
    BACKEND_PORT="${BACKEND_PORT:-22}"
    SSH_OPTS=(
      -i "$KEY_FILE"
      -p "$BACKEND_PORT"
      -o IdentitiesOnly=yes
      -o StrictHostKeyChecking=accept-new
      -o ConnectTimeout=10
      -o BatchMode=yes
    )
    if ssh -n "${SSH_OPTS[@]}" "root@$BACKEND_IP" true >/dev/null 2>&1; then
      backend_ok=1
      ok "SSH к BACKEND доступен"
    else
      warn "BACKEND недоступен по SSH: пропускаю удаление на BACKEND"
    fi
  else
    warn "Нет данных SSH до BACKEND: пропускаю удаление на BACKEND"
  fi

  if [ "$backend_ok" = 1 ]; then
    make_remote_scripts
    remote_script "$TMPD/be-uninstall.sh" "${RELAY_IP:-}" "${INTERNAL_PORT:-28443}" "${UNINSTALL_RM_XUI:-1}" >>"$LOG" 2>&1 || warn "часть действий на BACKEND не выполнена"
    ok "BACKEND: внутренние настройки удалены, если сервер был доступен"
  fi

  rm -f "$MARKER_FILE" "$CONF_FILE" "$REPORT_FILE" 2>/dev/null || true
  ok "метка, конфиг и отчёт удалены"
}

run_install() {
  INSTALL_KIND="secure-chain"
  STEP=0
  TOTAL=18

  check_reinstall
  STEP=0
  TOTAL=18

  KEY_FILE=""
  KEY_STORE_USED=0

  echo
  echo "${B}Параметры Secure Chain${R}"
  thin

  while true; do
    ask BACKEND_IP "IP BACKEND (зарубежный сервер, отдельный от RELAY)" "${BACKEND_IP:-}"
    if [ "$BACKEND_IP" = "$RELAY_IP" ]; then
      fail "Для анонимной цепочки BACKEND должен быть отдельным сервером"
      BACKEND_IP=""
      continue
    fi
    if valid_ip "$BACKEND_IP"; then
      break
    fi
    fail "неверный IP"
    BACKEND_IP=""
  done

  while true; do
    ask BACKEND_PORT "SSH-порт BACKEND" "${BACKEND_PORT:-22}"
    if valid_port "$BACKEND_PORT"; then
      break
    fi
    fail "неверный порт"
  done

  while true; do
    ask DOMAIN "Домен RELAY (A-запись -> IP этого сервера)" "${DOMAIN:-}"
    if valid_dom "$DOMAIN"; then
      break
    fi
    fail "неверный домен"
    DOMAIN=""
  done

  EMAIL="admin@$DOMAIN"
  DNS_TARGET="$RELAY_IP"

  echo
  section "Подключение к BACKEND"
  ssh_connect
  backend_os_check

  section "Подбор свободных портов на BACKEND"
  INTERNAL_PORT=$(choose_remote_port 28443 28444 28445 28446 28447 28448) || die "не найден свободный internal порт на BACKEND"
  XRAY_PORT=$(choose_remote_port 10000 10001 10002 10003 10004 10005 10006) || die "не найден свободный Xray порт на BACKEND"
  PANEL_PORT=$(choose_remote_port "$PANEL_PORT_DEFAULT" 998 1001 1002 2053 2096) || die "не найден свободный порт панели на BACKEND"
  ok "BACKEND internal port: $INTERNAL_PORT"
  ok "BACKEND Xray port: $XRAY_PORT"
  ok "BACKEND panel port: $PANEL_PORT"

  CHANNEL_PATH="/$(openssl rand -hex 8)/"
  UUID=$(new_uuid)
  XU=$(openssl rand -hex 5)
  XP=$(openssl rand -hex 10)
  XW="/$(openssl rand -hex 9)/"

  echo
  rule
  printf ' %sПлан установки%s\n' "$B" "$R"
  rule
  kv "RELAY IP" "$RELAY_IP"
  kv "RELAY domain" "$DOMAIN"
  kv "BACKEND IP" "$BACKEND_IP"
  kv "BACKEND SSH" "$BACKEND_PORT"
  kv "Public path" "$CHANNEL_PATH"
  kv "UUID" "$UUID"
  kv "Internal TLS" "$INTERNAL_NAME:$INTERNAL_PORT (mTLS)"
  kv "Xray local" "127.0.0.1:$XRAY_PORT"
  kv "Panel local" "127.0.0.1:$PANEL_PORT$XW"
  kv "RELAY ports" "SSH, 80/tcp, 443/tcp"
  kv "BACKEND ports" "SSH, $INTERNAL_PORT/tcp только от RELAY"
  kv "Tunnel" "без rathole, без xhttp; HTTPS/WSS -> internal mTLS -> VLESS WS"
  rule
  echo

  confirm "Всё верно, начать установку Secure Chain?" || { echo " Отменено."; exit 0; }

  write_marker in-progress
  make_remote_scripts

  section "Подготовка связки"
  remote_script "$TMPD/f2b-ignore.sh" "$RELAY_IP" >>"$LOG" 2>&1 || true
  tune_relay || warn "сетевые твики на RELAY применены не полностью"
  remote_script "$TMPD/be-tune.sh" >>"$LOG" 2>&1 || warn "сетевые твики на BACKEND применены не полностью"
  ok "fail2ban ignore и сетевые твики обработаны"

  section "RELAY: пакеты"
  relay_packages || die "не удалось подготовить RELAY"

  section "RELAY: firewall"
  relay_firewall || die "не удалось настроить firewall RELAY"

  section "Внутренний mTLS"
  generate_internal_tls || die "не удалось создать внутренний mTLS CA"
  deploy_backend_tls || die "не удалось доставить mTLS на BACKEND"

  section "RELAY: hosts"
  update_relay_hosts || die "не удалось обновить /etc/hosts"

  section "DNS"
  dns_check || true

  section "RELAY: Let's Encrypt"
  CERT_OK=0
  while true; do
    if relay_cert; then
      CERT_OK=1
      break
    fi
    warn "не удалось выпустить сертификат (DNS ещё не разошёлся? порт 80 недоступен?)"
    confirm "Повторить?" || break
  done
  [ "$CERT_OK" -eq 1 ] || die "для Secure Chain нужен валидный публичный сертификат на RELAY"

  section "RELAY: финальный nginx"
  relay_final_nginx || die "не удалось применить nginx на RELAY"

  section "RELAY: helper"
  install_relay_helper || warn "secure-chain-set-backend не установлен"

  section "BACKEND: пакеты"
  remote_script "$TMPD/be-pkgs.sh" >>"$LOG" 2>&1 || die "не удалось подготовить BACKEND"

  section "BACKEND: 3x-ui"
  remote_script "$TMPD/be-xui.sh" "$PANEL_PORT" "$XU" "$XP" "$XW" >>"$LOG" 2>&1 || die "не удалось установить/настроить 3x-ui"

  section "BACKEND: internal nginx"
  remote_script "$TMPD/be-nginx.sh" \
    "$DOMAIN" \
    "$INTERNAL_NAME" \
    "$INTERNAL_PORT" \
    "$XRAY_PORT" \
    "$CHANNEL_PATH" \
    "$BACKEND_WEBROOT" \
    "/etc/secure-chain/tls" >>"$LOG" 2>&1 || die "не удалось настроить internal nginx на BACKEND"

  section "BACKEND: firewall"
  remote_script "$TMPD/be-fw.sh" "$RELAY_IP" "$INTERNAL_PORT" >>"$LOG" 2>&1 || die "не удалось настроить firewall BACKEND"

  section "BACKEND: VLESS WS inbound через API 3x-ui"
  if remote_script "$TMPD/be-api.sh" \
      "$PANEL_PORT" \
      "$XW" \
      "$XU" \
      "$XP" \
      "$UUID" \
      "$XRAY_PORT" \
      "$CHANNEL_PATH" \
      "$DOMAIN" >>"$LOG" 2>&1; then
    ok "VLESS WS inbound создан через API 3x-ui"
  else
    warn "не удалось создать inbound через API 3x-ui — создайте вручную по инструкциям ниже"
  fi

  section "Сохранение настроек"
  save_conf
  write_marker done
  ok "настройки сохранены: $CONF_FILE"

  section "Проверка"
  post_checks || true

  local sc_ws_enc
  sc_ws_enc=$(urlencode_path "$CHANNEL_PATH")

  {
    echo "Secure Chain v$VERSION — $(date '+%F %T')"
    echo "RELAY: $RELAY_IP"
    echo "RELAY domain: $DOMAIN"
    echo "BACKEND: $BACKEND_IP (SSH :$BACKEND_PORT)"
    echo "WebSocket path: $CHANNEL_PATH"
    echo "UUID: $UUID"
    echo "Internal TLS: $INTERNAL_NAME:$INTERNAL_PORT"
    echo "Xray local: 127.0.0.1:$XRAY_PORT"
    echo "Panel local: http://127.0.0.1:$PANEL_PORT$XW"
    echo "Username: $XU"
    echo "Password: $XP"
    echo "Key file: ${KEY_FILE:-}"
    echo "Key stored by script: ${KEY_STORE_USED:-0}"
  } > "$REPORT_FILE"
  chmod 600 "$REPORT_FILE" || true

  echo
  rule
  printf ' %sУСТАНОВКА ЗАВЕРШЕНА%s\n' "$GRN" "$R"
  rule

  printf ' %sПубличный вход для клиента%s\n' "$B" "$R"
  printf ' URL: %shttps://%s%s%s\n' "$B" "$DOMAIN" "$CHANNEL_PATH" "$R"
  echo

  printf ' %sIncy / VLESS link%s\n' "$B" "$R"
  printf 'vless://%s@%s:443?encryption=none&security=tls&type=ws&path=%s&host=%s&sni=%s&fp=chrome#SecureChain\n' \
    "$UUID" "$DOMAIN" "$sc_ws_enc" "$DOMAIN" "$DOMAIN"
  echo

  printf ' %sПанель 3x-ui%s\n' "$B" "$R"
  echo " Панель слушает только на BACKEND 127.0.0.1:$PANEL_PORT$XW"
  echo " Доступ через SSH-туннель с RELAY:"
  echo "   ssh -i $KEY_FILE -p $BACKEND_PORT root@$BACKEND_IP -L 9999:127.0.0.1:$PANEL_PORT"
  echo " Затем в браузере:"
  echo "   http://127.0.0.1:9999$XW"
  echo " Username: $XU"
  echo " Password: $XP"
  echo

  printf ' %sЕсли API не создал inbound, создайте вручную%s\n' "$YLW" "$R"
  echo " • Protocol: VLESS"
  echo " • Listen IP: 127.0.0.1"
  echo " • Port: $XRAY_PORT"
  echo " • Transport: WebSocket"
  echo " • TLS на Xray: none (TLS терминирует nginx)"
  echo " • WS path: $CHANNEL_PATH"
  echo " • WS host: $DOMAIN"
  echo " • Client UUID: $UUID"
  echo

  printf ' %sСмена IP BACKEND%s\n' "$B" "$R"
  echo " На RELAY выполните:"
  echo "   secure-chain-set-backend НОВЫЙ_IP_BACKEND"
  echo " Если менялся IP RELAY, также обновите firewall на BACKEND:"
  echo "   ufw delete allow from СТАРЫЙ_RELAY_IP to any port $INTERNAL_PORT proto tcp"
  echo "   ufw allow from НОВЫЙ_RELAY_IP to any port $INTERNAL_PORT proto tcp"
  echo

  echo " ${DIM}Отчёт: $REPORT_FILE (права 600)${R}"
  echo " ${DIM}Лог: $LOG${R}"
  echo
}

menu() {
  local has=0 c
  [ -f "$MARKER_FILE" ] && has=1

  echo
  echo " ${B}1${R}. Установить Secure Chain (RELAY + BACKEND)"
  if [ "$has" -eq 1 ]; then
    echo " ${B}2${R}. Откатить установку"
  else
    echo " ${B}2${R}. Откатить установку ${DIM}(нет метки)${R}"
  fi

  while true; do
    if [ -r /dev/tty ]; then
      read -r -p " ${B}?${R} Выберите вариант: " c </dev/tty || c=""
    else
      read -r -p " ${B}?${R} Выберите вариант: " c || c=""
    fi

    case "$c" in
      1) MODE="install"; return 0 ;;
      2)
        if [ "$has" -eq 1 ]; then
          MODE="uninstall"
          return 0
        fi
        fail "вариант 2 доступен только после установки"
        ;;
      *)
        fail "введите 1 или 2"
        ;;
    esac
  done
}

main() {
  [ "$(id -u)" -eq 0 ] || { echo "Запустите от root: sudo bash $0"; exit 1; }

  mkdir -p "$(dirname "$LOG")" 2>/dev/null || true
  : > "$LOG"
  chmod 600 "$LOG" 2>/dev/null || true

  TMPD=$(mktemp -d /tmp/secure-chain.XXXXXX)

  banner
  ensure_tools || die "не удалось установить базовые утилиты на RELAY"

  RELAY_IP=$(detect_relay_ip)
  valid_ip "$RELAY_IP" || die "не удалось определить публичный IPv4 RELAY"
  ok "RELAY IP: $RELAY_IP"

  load_conf

  menu

  case "$MODE" in
    install) run_install ;;
    uninstall) do_uninstall ;;
  esac
}

if [ -z "${BASH_SOURCE[0]:-}" ] || [ "${BASH_SOURCE[0]}" = "$0" ]; then
  main "$@"
fi
