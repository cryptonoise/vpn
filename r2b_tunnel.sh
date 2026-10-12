#!/usr/bin/env bash
#
# relay-setup.sh — RELAY·BACKEND Tunnel Setup
# Запускать на RELAY (РФ-сервер) от root:  bash relay-setup.sh
#
# Что делает:
#   RELAY   — rathole-server, ufw, пересылка UDP 8443 (Hysteria2)
#   BACKEND — (по SSH) пакеты, rathole-client, 3x-ui, nginx, сертификат Let's Encrypt, ufw
# Итог: данные для входа в панель по https://домен/<WebBasePath>
# Требования: Ubuntu 22.04+ на обоих серверах, root-доступ, SSH-ключ root для BACKEND
# Туннель rathole работает по TLS (свой CA, SNI = домен панели). Noise-транспорт не используется:
# поток из случайных байт сам по себе выглядит подозрительно.
#
VERSION="1.2.1"
NAME="RELAY·BACKEND Tunnel Setup"

set -u
set -o pipefail

# ───────────────────────── пути (переопределяются для тестов) ─────────────────────────
UFW_BEFORE="${UFW_BEFORE:-/etc/ufw/before.rules}"
UFW_SYSCTL="${UFW_SYSCTL:-/etc/ufw/sysctl.conf}"
CONF_FILE="${CONF_FILE:-/root/.relay-setup.conf}"
REPORT_FILE="${REPORT_FILE:-/root/relay-setup-report.txt}"
LOG="${LOG:-/var/log/relay-setup.log}"
TLS_DIR="${TLS_DIR:-/etc/rathole/tls}"
PANEL_PORT=999
TOTAL=13
STEP=0

# ───────────────────────── цвета ─────────────────────────
if [ -t 1 ]; then
  R=$'\e[0m'; B=$'\e[1m'; DIM=$'\e[2m'
  RED=$'\e[31m'; GRN=$'\e[32m'; YLW=$'\e[33m'; BLU=$'\e[34m'; CYN=$'\e[36m'
else
  R=; B=; DIM=; RED=; GRN=; YLW=; BLU=; CYN=
fi
SPIN=(⠋ ⠙ ⠹ ⠸ ⠼ ⠴ ⠦ ⠧ ⠇ ⠏)

# ───────────────────────── вывод ─────────────────────────
rule()  { printf '%s' "$CYN"; printf '═%.0s' $(seq 1 60); printf '%s\n' "$R"; }
thin()  { printf '%s' "$DIM"; printf '─%.0s' $(seq 1 60); printf '%s\n' "$R"; }
ok()    { printf '  %s✔%s %s\n' "$GRN" "$R" "$*"; }
warn()  { printf '  %s▲%s %s\n' "$YLW" "$R" "$*"; }
fail()  { printf '  %s✖%s %s\n' "$RED" "$R" "$*"; }
info()  { printf '  %s•%s %s\n' "$BLU" "$R" "$*"; }
kv()    { printf '  %s%-14s%s %s\n' "$DIM" "$1" "$R" "$2"; }

section() {
  STEP=$((STEP + 1))
  echo
  printf '%s[%d/%d]%s %s%s%s\n' "$CYN" "$STEP" "$TOTAL" "$R" "$B" "$*" "$R"
  thin
}

banner() {
  clear 2>/dev/null || true
  rule
  printf '  %s%s%s\n' "$B" "$NAME" "$R"
  printf '  %sверсия %s%s\n' "$DIM" "$VERSION" "$R"
  rule
  echo "  Настройка связки «РФ-реле + обратный туннель + запасной UDP»:"
  echo "   • RELAY (этот сервер): rathole-server, firewall, пересылка UDP"
  echo "   • BACKEND (по SSH): 3x-ui, nginx, сертификат, firewall"
  echo "   • в конце — данные для входа в панель по домену (https)"
  rule
  echo
  read -r -p "  Нажмите Enter, чтобы начать." _
  echo
}

# ───────────────────────── ввод ─────────────────────────
ask() {  # ask VAR "Вопрос" "по умолчанию"
  local __v="$1" q="$2" d="${3:-}" a
  if [ -n "$d" ]; then
    read -r -p "${B}?${R} $q ${DIM}[$d]${R}: " a
    a="${a:-$d}"
  else
    read -r -p "${B}?${R} $q: " a
  fi
  printf -v "$__v" '%s' "$a"
}

confirm() {  # Enter / y = да, n = нет
  local a
  while true; do
    read -r -p "${B}?${R} $1 ${DIM}[Enter/y — да, n — нет]${R}: " a
    case "${a:-y}" in
      y | Y | yes | YES | д | Д) return 0 ;;
      n | N | no | NO | н | Н | нет) return 1 ;;
      *) printf '  %sВведите Enter / y (да) или n (нет)%s\n' "$DIM" "$R" ;;
    esac
  done
}

valid_ip()   { [[ "$1" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] && ! [[ "$1" =~ (^|\.)(25[6-9]|2[6-9][0-9]|[3-9][0-9]{2})(\.|$) ]]; }
valid_port() { [[ "$1" =~ ^[0-9]+$ ]] && [ "$1" -ge 1 ] && [ "$1" -le 65535 ]; }
version_ge() { [ "$(printf '%s\n%s\n' "$1" "$2" | sort -V | head -n1)" = "$2" ]; }
valid_dom()  { [[ "$1" =~ ^([a-zA-Z0-9]([a-zA-Z0-9-]*[a-zA-Z0-9])?\.)+[a-zA-Z]{2,}$ ]]; }

# ───────────────────────── выполнение шагов с анимацией ─────────────────────────
step_run() {  # step_run "Описание" команда args...
  local label="$1"
  shift
  local t0=$SECONDS pid rc i=0
  ( "$@" </dev/null >>"$LOG" 2>&1 ) &
  pid=$!
  if [ -t 1 ]; then
    while kill -0 "$pid" 2>/dev/null; do
      printf '\r  %s%s%s %s %s(%ds)%s\033[K' "$CYN" "${SPIN[i % 10]}" "$R" "$label" "$DIM" $((SECONDS - t0)) "$R"
      i=$((i + 1))
      sleep 0.1
    done
    printf '\r\033[K'
  fi
  wait "$pid"
  rc=$?
  if [ $rc -eq 0 ]; then
    ok "$label ${DIM}($((SECONDS - t0))с)${R}"
  else
    fail "$label"
    echo "${DIM}    ── последние строки лога ($LOG) ──${R}"
    tail -n 12 "$LOG" | sed 's/^/    /'
  fi
  return $rc
}

die() {
  echo
  fail "$*"
  echo "  ${DIM}Полный лог: $LOG${R}"
  exit 1
}

# ───────────────────────── общие функции (уходят и на BACKEND) ─────────────────────────
rathole_asset() {
  case "$(uname -m)" in
    x86_64 | amd64) echo "rathole-x86_64-unknown-linux-gnu.zip" ;;
    aarch64 | arm64) echo "rathole-aarch64-unknown-linux-musl.zip" ;;
    *) echo "unsupported arch: $(uname -m)" >&2; return 1 ;;
  esac
}

rathole_install() {
  local asset tmp
  asset=$(rathole_asset) || return 1
  tmp=$(mktemp -d) || return 1
  curl -fsSL --retry 3 -o "$tmp/r.zip" "https://github.com/rapiz1/rathole/releases/latest/download/$asset" || return 1
  unzip -oq "$tmp/r.zip" -d "$tmp" || return 1
  install -m 755 "$tmp/rathole" /usr/local/bin/rathole || return 1
  rm -rf "$tmp"
  test -x /usr/local/bin/rathole
}

# GitHub из РФ бывает недоступен: тогда архив скачивает BACKEND и передаёт на RELAY
rathole_install_via_backend() {
  local asset tmp
  asset=$(rathole_asset) || return 1
  tmp=$(mktemp -d) || return 1
  bk "curl -fsSL --retry 3 https://github.com/rapiz1/rathole/releases/latest/download/$asset" > "$tmp/r.zip" || return 1
  unzip -oq "$tmp/r.zip" -d "$tmp" || return 1
  install -m 755 "$tmp/rathole" /usr/local/bin/rathole || return 1
  rm -rf "$tmp"
  test -x /usr/local/bin/rathole
}

# порты, на которых слушает sshd (+ порт текущего SSH-подключения; Ubuntu 22.10+ — ssh.socket)
ssh_ports() {
  {
    ss -tlnp 2>/dev/null | awk '/"sshd"/ { n = split($4, a, ":"); print a[n] }'
    sshd -T 2>/dev/null | awk '/^port / { print $2 }'
    systemctl show ssh.socket -p Listen 2>/dev/null | sed -n 's/^Listen=.*:\([0-9][0-9]*\) (Stream)$/\1/p'
    [ -n "${SSH_CONNECTION:-}" ] && echo "$SSH_CONNECTION" | awk '{ print $4 }'
  } | grep -E '^[0-9]+$' | sort -un
}

# ───────────────────────── RELAY: подготовка ─────────────────────────
relay_prepare() {
  export DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=a
  apt-get -o DPkg::Lock::Timeout=300 update -y &&
    apt-get -o DPkg::Lock::Timeout=300 install -y curl unzip ufw dnsutils openssh-client ca-certificates openssl iproute2 || return 1
  rathole_install || { echo "прямая загрузка rathole не удалась, пробую через BACKEND"; rathole_install_via_backend; }
}

# базовые утилиты нужны ещё до вопросов (curl, dig, ssh, openssl, ss)
ensure_tools() {
  local miss=()
  command -v curl >/dev/null 2>&1 || miss+=(curl)
  command -v dig >/dev/null 2>&1 || miss+=(dnsutils)
  { command -v ssh >/dev/null 2>&1 && command -v ssh-keygen >/dev/null 2>&1; } || miss+=(openssh-client)
  command -v openssl >/dev/null 2>&1 || miss+=(openssl)
  command -v ss >/dev/null 2>&1 || miss+=(iproute2)
  [ ${#miss[@]} -eq 0 ] && return 0
  info "устанавливаю: ${miss[*]}"
  export DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=a
  apt-get -o DPkg::Lock::Timeout=300 update -y >>"$LOG" 2>&1 &&
    apt-get -o DPkg::Lock::Timeout=300 install -y "${miss[@]}" >>"$LOG" 2>&1
}

detect_relay_ip() {
  local ip=""
  for u in https://api.ipify.org https://ifconfig.me https://icanhazip.com; do
    ip=$(curl -4 -fsS --max-time 6 "$u" 2>/dev/null | tr -d '[:space:]')
    valid_ip "$ip" && break
    ip=""
  done
  if [ -z "$ip" ]; then
    ip=$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{ for (i = 1; i <= NF; i++) if ($i == "src") print $(i + 1) }' | head -1)
  fi
  printf '%s' "$ip"
}

# ───────────────────────── RELAY: rathole-server ─────────────────────────
# свой CA и серверный сертификат для домена; PKCS#12 нужен rathole-server.
# Сертификат привязан к имени (домену), не к IP — поэтому identity.pfx годится для любого нового RELAY.
relay_tls_setup() {
  local d="$TLS_DIR"
  mkdir -p "$d" && chmod 700 "$d" || return 1
  if [ -f "$d/identity.pfx" ] && [ -f "$d/srv.pem" ] &&
    openssl x509 -in "$d/srv.pem" -noout -ext subjectAltName 2>/dev/null | grep -q "DNS:$DOMAIN"; then
    return 0   # уже есть сертификат для этого домена — CA не меняем
  fi
  openssl req -x509 -newkey rsa:2048 -nodes -keyout "$d/ca.key" -out "$d/ca.pem" -days 3650 -subj "/CN=rathole-ca" &&
    openssl req -newkey rsa:2048 -nodes -keyout "$d/srv.key" -out "$d/srv.csr" -subj "/CN=$DOMAIN" &&
    printf 'subjectAltName=DNS:%s\nbasicConstraints=CA:FALSE\nkeyUsage=digitalSignature,keyEncipherment\nextendedKeyUsage=serverAuth\n' "$DOMAIN" > "$d/ext.cnf" &&
    openssl x509 -req -in "$d/srv.csr" -CA "$d/ca.pem" -CAkey "$d/ca.key" -CAcreateserial -out "$d/srv.pem" -days 3650 -extfile "$d/ext.cnf" &&
    openssl rand -hex 16 > "$d/pfx.pass" &&
    openssl pkcs12 -export -out "$d/identity.pfx" -inkey "$d/srv.key" -in "$d/srv.pem" -certfile "$d/ca.pem" -passout "pass:$(cat "$d/pfx.pass")" &&
    chmod 600 "$d"/* &&
    rm -f "$d/srv.csr" "$d/ca.srl"
}

# BACKEND: CA для проверки сервера + резервная копия identity (для замены RELAY) + rathole-client
backend_rathole() {
  bk "mkdir -p /etc/rathole/relay-tls && chmod 700 /etc/rathole/relay-tls" &&
    bk "cat > /etc/rathole/ca.pem" < "$TLS_DIR/ca.pem" &&
    tar -C "$TLS_DIR" -cf - identity.pfx pfx.pass ca.pem | bk "tar -C /etc/rathole/relay-tls -xf - && chmod 600 /etc/rathole/relay-tls/*" &&
    rscript "$TMPD/rathole-client.sh" "$RELAY_IP" "$SECRET" "$DOMAIN"
}

relay_rathole_server() {
  mkdir -p /etc/rathole
  local pfx_pw
  pfx_pw=$(cat "$TLS_DIR/pfx.pass") || return 1
  cat > /etc/rathole/server.toml <<EOF
[server]
bind_addr = "0.0.0.0:2333"
default_token = "$SECRET"

[server.transport]
type = "tls"

[server.transport.tls]
pkcs12 = "$TLS_DIR/identity.pfx"
pkcs12_password = "$pfx_pw"

[server.services.https]
bind_addr = "0.0.0.0:443"

[server.services.http]
bind_addr = "0.0.0.0:80"

[server.services.reality]
bind_addr = "0.0.0.0:8443"
EOF
  chmod 600 /etc/rathole/server.toml
  cat > /etc/systemd/system/rathole.service <<'EOF'
[Unit]
Description=rathole server
After=network-online.target
Wants=network-online.target

[Service]
ExecStart=/usr/local/bin/rathole --server /etc/rathole/server.toml
Restart=always
RestartSec=3
LimitNOFILE=65535

[Install]
WantedBy=multi-user.target
EOF
  systemctl daemon-reload &&
    systemctl enable rathole >/dev/null 2>&1 &&
    systemctl restart rathole &&
    sleep 2 &&
    systemctl is-active --quiet rathole
}

# порты 2333/443/80/8443 не должны быть заняты чужими процессами
relay_port_conflicts() {
  local bad=""
  for p in 2333 443 80 8443; do
    local owner
    owner=$(ss -tlnp 2>/dev/null | awk -v p=":$p" '$4 ~ p"$" { print $0 }' | grep -v rathole | head -1)
    [ -n "$owner" ] && bad="$bad $p"
  done
  printf '%s' "$bad"
}

# ───────────────────────── RELAY: ufw + пересылка UDP ─────────────────────────
# NAT для UDP 8443 кладётся в before.rules ufw (переживает перезагрузку и ufw reload)
relay_nat_block() {
  cat <<EOF
# BEGIN relay-setup-nat
*nat
:PREROUTING ACCEPT [0:0]
:POSTROUTING ACCEPT [0:0]
-A PREROUTING -p udp --dport 8443 -j DNAT --to-destination $BACKEND_IP:8443
-A POSTROUTING -p udp -d $BACKEND_IP --dport 8443 -j MASQUERADE
COMMIT
# END relay-setup-nat

EOF
}

relay_apply_nat() {
  [ -f "$UFW_BEFORE" ] || return 1
  cp -n "$UFW_BEFORE" "$UFW_BEFORE.bak.relay-setup" 2>/dev/null || true
  sed -i '/^# BEGIN relay-setup-nat$/,/^# END relay-setup-nat$/d' "$UFW_BEFORE"
  { relay_nat_block; cat "$UFW_BEFORE"; } > "$UFW_BEFORE.new" &&
    cat "$UFW_BEFORE.new" > "$UFW_BEFORE" &&
    rm -f "$UFW_BEFORE.new"
}

relay_enable_forwarding() {
  touch "$UFW_SYSCTL"
  if grep -qE '^#?net/ipv4/ip_forward=' "$UFW_SYSCTL"; then
    sed -i 's|^#\?net/ipv4/ip_forward=.*|net/ipv4/ip_forward=1|' "$UFW_SYSCTL"
  else
    echo 'net/ipv4/ip_forward=1' >> "$UFW_SYSCTL"
  fi
  echo 'net.ipv4.ip_forward = 1' > /etc/sysctl.d/99-relay-forward.conf
  sysctl -w net.ipv4.ip_forward=1 >/dev/null
}

# убираем старые TCP-DNAT правила (остались от прежней схемы без rathole) — они обходят rathole
relay_cleanup_old_dnat() {
  local rule
  while read -r rule; do
    [ -z "$rule" ] && continue
    # shellcheck disable=SC2086
    iptables -t nat ${rule/-A/-D} 2>/dev/null || true
  done < <(iptables -t nat -S PREROUTING 2>/dev/null | grep -E -- '-p tcp .*--dport (443|80|8443) .*DNAT')
  if command -v netfilter-persistent >/dev/null 2>&1; then netfilter-persistent save >/dev/null 2>&1 || true; fi
}

relay_firewall() {
  local p ports
  ports=$(ssh_ports)
  [ -n "$ports" ] || { echo "SSH-порт RELAY не определён: firewall не включаю, чтобы не потерять доступ" >&2; return 1; }
  relay_cleanup_old_dnat
  for p in $ports; do ufw allow "$p/tcp" || return 1; done
  ufw allow from "$BACKEND_IP" to any port 2333 proto tcp || return 1
  ufw allow 443/tcp && ufw allow 80/tcp && ufw allow 8443/tcp && ufw allow 8443/udp || return 1
  ufw route allow proto udp from any to "$BACKEND_IP" port 8443 || return 1
  relay_enable_forwarding || return 1
  relay_apply_nat || return 1
  ufw --force enable >/dev/null && ufw --force reload >/dev/null
}

# ───────────────────────── DNS ─────────────────────────
dns_collect() {  # IPv4 из нескольких резолверов + системного
  local d
  for d in 8.8.8.8 1.1.1.1 77.88.8.8; do
    dig +short +time=3 +tries=1 A "$DOMAIN" @"$d" 2>/dev/null
  done
  getent ahostsv4 "$DOMAIN" 2>/dev/null | awk '{ print $1 }'
}

dns_check() {
  local all v6 x
  while true; do
    all=$(dns_collect | grep -E '^[0-9]{1,3}(\.[0-9]{1,3}){3}$' | sort -u | tr '\n' ' ')
    all="${all% }"
    v6=$(dig +short +time=3 +tries=1 AAAA "$DOMAIN" @8.8.8.8 2>/dev/null | grep ':' | head -1)
    if [ "$all" = "$RELAY_IP" ] && [ -z "$v6" ]; then
      ok "DNS: $DOMAIN → $RELAY_IP"
      return 0
    fi
    echo
    rule
    printf '  %s▲ Проблема с DNS%s\n' "$YLW" "$R"
    echo "  Домен:        $DOMAIN"
    echo "  Сейчас:       A: ${all:-нет}   AAAA: ${v6:-нет}"
    echo "  Должно быть:  A = $RELAY_IP (IP RELAY, DNS only, TTL 1 мин), AAAA — удалить"
    echo "  ${DIM}(IPv6 через туннель не пробрасывается, а Let's Encrypt проверяет по IPv6 первым)${R}"
    rule
    read -r -p "  Нажмите Enter, когда исправили (n — пропустить проверку): " x
    if [[ "$x" =~ ^[nNнН] ]]; then
      warn "проверка DNS пропущена — сертификат может не выпуститься"
      return 1
    fi
  done
}

# ───────────────────────── SSH к BACKEND ─────────────────────────
read_key() {
  local line default_key="" f
  for f in /root/.ssh/id_ed25519 /root/.ssh/id_rsa /root/.ssh/id_ecdsa; do
    [ -f "$f" ] && { default_key="$f"; break; }
  done
  while true; do
    echo "${B}?${R} Приватный ключ root для BACKEND: путь к файлу или вставьте ключ целиком ${DIM}(ввод скрыт)${R}"
    [ -n "$default_key" ] && echo "  ${DIM}Enter — ключ этого сервера: $default_key${R}"
    IFS= read -r -s line
    echo
    line="${line//$'\r'/}"
    if [ -z "$line" ]; then
      if [ -n "$default_key" ]; then KEY_FILE="$default_key"; else fail "ключ не найден на этом сервере, укажите путь или вставьте ключ"; continue; fi
    elif [[ "$line" == -----BEGIN* ]]; then
      KEY_FILE="$TMPD/key"
      printf '%s\n' "$line" > "$KEY_FILE"
      while IFS= read -r -s line; do
        line="${line//$'\r'/}"
        printf '%s\n' "$line" >> "$KEY_FILE"
        [[ "$line" == -----END* ]] && break
      done
      chmod 600 "$KEY_FILE"
    elif [ -f "$line" ]; then
      KEY_FILE="$line"
    else
      fail "файл не найден: $line"
      continue
    fi
    if ssh-keygen -y -P "" -f "$KEY_FILE" > "$TMPD/key.pub" 2>/dev/null; then
      ok "ключ принят"
      return 0
    fi
    fail "ключ не читается (неверный формат или защищён паролем — такие не поддерживаются)"
  done
}

ssh_opts() {
  SSH_OPTS=(-i "$KEY_FILE" -p "$BACKEND_PORT" -o IdentitiesOnly=yes
    -o StrictHostKeyChecking=accept-new -o ServerAliveInterval=15 -o ServerAliveCountMax=4
    -o ConnectTimeout=15 -o ControlMaster=auto -o "ControlPath=$TMPD/cm-%C" -o ControlPersist=1800)
}

bk()      { ssh "${SSH_OPTS[@]}" "root@$BACKEND_IP" "$@"; }
rscript() { local f="$1"; shift; ssh "${SSH_OPTS[@]}" "root@$BACKEND_IP" bash -s -- "$@" < "$f"; }

ssh_connect() {
  local err np
  ssh_opts
  while true; do
    if ssh "${SSH_OPTS[@]}" -o BatchMode=yes "root@$BACKEND_IP" true >/dev/null 2>"$TMPD/ssh.err"; then
      ok "SSH: root@$BACKEND_IP:$BACKEND_PORT"
      return 0
    fi
    err=$(cat "$TMPD/ssh.err")
    if echo "$err" | grep -q 'REMOTE HOST IDENTIFICATION HAS CHANGED'; then
      warn "ключ хоста BACKEND изменился (сервер переустанавливали?)"
      confirm "Удалить старую запись из known_hosts и продолжить?" || die "подключение отменено"
      ssh-keygen -R "$BACKEND_IP" >/dev/null 2>&1 || true
      ssh-keygen -R "[$BACKEND_IP]:$BACKEND_PORT" >/dev/null 2>&1 || true
    elif echo "$err" | grep -qi 'permission denied'; then
      fail "BACKEND не принял ключ: его публичная часть должна быть в authorized_keys пользователя root на BACKEND"
      confirm "Указать другой приватный ключ?" || die "без доступа по ключу к BACKEND продолжить нельзя"
      read_key
    else
      fail "SSH не удался: $(echo "$err" | tail -n 1)"
      confirm "Повторить?" || die "без SSH к BACKEND продолжить нельзя"
      ask np "SSH-порт BACKEND" "$BACKEND_PORT"
      valid_port "$np" && BACKEND_PORT="$np"
    fi
    ssh_opts
  done
}

# ───────────────────────── удалённые скрипты (создаются в $TMPD) ─────────────────────────
make_remote_scripts() {
  local D="$TMPD"

  cat > "$D/pkgs.sh" <<'EOF'
set -e
export DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=a
APT="apt-get -o DPkg::Lock::Timeout=300"
$APT update -y
$APT upgrade -y -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold
$APT install -y curl wget sudo nginx certbot dnsutils unzip ufw ca-certificates openssl python3
timedatectl set-timezone Europe/Moscow || true
EOF

  { declare -f rathole_asset rathole_install; cat <<'EOF'
set -e
RELAY="$1"; SECRET="$2"; DOMAIN="$3"
rathole_install
mkdir -p /etc/rathole
cat > /etc/rathole/client.toml <<EOT
[client]
remote_addr = "$RELAY:2333"
default_token = "$SECRET"

[client.transport]
type = "tls"

[client.transport.tls]
trusted_root = "/etc/rathole/ca.pem"
hostname = "$DOMAIN"

[client.services.https]
local_addr = "127.0.0.1:443"

[client.services.http]
local_addr = "127.0.0.1:80"

[client.services.reality]
local_addr = "127.0.0.1:8443"
EOT
chmod 600 /etc/rathole/client.toml
cat > /etc/systemd/system/rathole.service <<'EOT'
[Unit]
Description=rathole client
After=network-online.target
Wants=network-online.target

[Service]
ExecStart=/usr/local/bin/rathole --client /etc/rathole/client.toml
Restart=always
RestartSec=3
LimitNOFILE=65535

[Install]
WantedBy=multi-user.target
EOT
systemctl daemon-reload
systemctl enable rathole >/dev/null 2>&1
systemctl restart rathole
sleep 3
systemctl is-active --quiet rathole
EOF
  } > "$D/rathole-client.sh"

  cat > "$D/xui.sh" <<'EOF'
set -e
export XUI_NONINTERACTIVE=1 XUI_DB_TYPE=sqlite XUI_SSL_MODE=none XUI_PANEL_PORT="$1"
curl -fsSL https://raw.githubusercontent.com/mhsanaei/3x-ui/master/install.sh -o /tmp/3xui-install.sh
bash /tmp/3xui-install.sh </dev/null
/usr/local/x-ui/x-ui setting -listenIP 127.0.0.1 || true
systemctl restart x-ui
sleep 3
systemctl is-active --quiet x-ui
ss -tlnH | grep -q "127.0.0.1:$1"
EOF

  cat > "$D/nginx-temp.sh" <<'EOF'
set -e
DOMAIN="$1"
cat > /etc/nginx/sites-available/apex.conf <<EOT
server {
    listen 80;
    listen [::]:80;
    server_name $DOMAIN;

    server_tokens off;
    add_header X-Content-Type-Options "nosniff" always;
    add_header X-Frame-Options "SAMEORIGIN" always;
    add_header Referrer-Policy "strict-origin-when-cross-origin" always;

    location / {
        proxy_pass http://127.0.0.1:999/;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
    }
}
EOT
ln -sf /etc/nginx/sites-available/apex.conf /etc/nginx/sites-enabled/apex.conf
nginx -t
systemctl enable --now nginx
systemctl reload nginx
EOF

  cat > "$D/cert.sh" <<'EOF'
DOMAIN="$1"; EMAIL="$2"
systemctl stop nginx
certbot certonly --standalone --preferred-challenges http -d "$DOMAIN" --non-interactive --agree-tos -m "$EMAIL"
rc=$?
systemctl start nginx
exit $rc
EOF

  cat > "$D/nginx-final.sh" <<'EOF'
set -e
DOMAIN="$1"
cat > /etc/nginx/sites-available/apex.conf <<EOT
server {
    listen 80;
    listen [::]:80;
    server_name $DOMAIN;
    return 301 https://\$host\$request_uri;
}

server {
    listen 443 ssl http2;
    listen [::]:443 ssl http2;
    server_name $DOMAIN;

    ssl_certificate     /etc/letsencrypt/live/$DOMAIN/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/$DOMAIN/privkey.pem;
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_ciphers HIGH:!aNULL:!MD5;
    ssl_prefer_server_ciphers on;
    ssl_session_cache shared:SSL:10m;
    ssl_session_timeout 10m;
    ssl_session_tickets off;

    server_tokens off;
    add_header X-Content-Type-Options "nosniff" always;
    add_header X-Frame-Options "SAMEORIGIN" always;
    add_header Referrer-Policy "strict-origin-when-cross-origin" always;
    add_header Strict-Transport-Security "max-age=63072000; includeSubDomains" always;

    location /waw/ {
        proxy_pass http://127.0.0.1:2096/waw/;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
    }

    location / {
        proxy_pass http://127.0.0.1:999/;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
    }
}
EOT
nginx -t
systemctl reload nginx
mkdir -p /etc/letsencrypt/renewal-hooks/pre /etc/letsencrypt/renewal-hooks/post /etc/letsencrypt/renewal-hooks/deploy
printf '#!/bin/bash\nsystemctl stop nginx\n' > /etc/letsencrypt/renewal-hooks/pre/stop-nginx.sh
printf '#!/bin/bash\nsystemctl start nginx\n' > /etc/letsencrypt/renewal-hooks/post/start-nginx.sh
printf '#!/bin/bash\nsystemctl reload nginx\n' > /etc/letsencrypt/renewal-hooks/deploy/reload-nginx.sh
chmod +x /etc/letsencrypt/renewal-hooks/pre/stop-nginx.sh /etc/letsencrypt/renewal-hooks/post/start-nginx.sh /etc/letsencrypt/renewal-hooks/deploy/reload-nginx.sh
systemctl enable --now certbot.timer
EOF

  cat > "$D/ufw-backend.sh" <<'EOF'
set -e
RELAY="$1"
ports=$( {
  ss -tlnp 2>/dev/null | awk '/"sshd"/ { n = split($4, a, ":"); print a[n] }'
  sshd -T 2>/dev/null | awk '/^port / { print $2 }'
  systemctl show ssh.socket -p Listen 2>/dev/null | sed -n 's/^Listen=.*:\([0-9][0-9]*\) (Stream)$/\1/p'
  [ -n "${SSH_CONNECTION:-}" ] && echo "$SSH_CONNECTION" | awk '{ print $4 }'
} | grep -E '^[0-9]+$' | sort -un || true )
[ -n "$ports" ] || { echo "sshd port not found" >&2; exit 1; }
for p in $ports; do ufw allow "$p/tcp"; done
for r in "443/tcp" "80/tcp" "8443/tcp" "443" "80" "8443" "Nginx Full" "Nginx HTTP" "Nginx HTTPS"; do
  ufw delete allow "$r" >/dev/null 2>&1 || true
done
for p in 443 80 8443; do
  ufw delete allow from "$RELAY" to any port "$p" proto tcp >/dev/null 2>&1 || true
done
ufw allow from "$RELAY" to any port 8443 proto udp
ufw --force enable
ufw status
EOF

  cat > "$D/helper-backend.sh" <<'EOF'
set -e
cat > /usr/local/bin/switch-relay <<'EOT'
#!/bin/bash
set -e
NEW="$1"; [ -z "$NEW" ] && { echo "usage: switch-relay НОВЫЙ_IP_РЕЛЕЯ"; exit 1; }
CFG=/etc/rathole/client.toml
OLD=$(grep -oP '(?<=remote_addr = ")[0-9.]+' $CFG)
sed -i "s/$OLD:2333/$NEW:2333/" $CFG
ufw delete allow from $OLD to any port 8443 proto udp || true
ufw allow from $NEW to any port 8443 proto udp
systemctl restart rathole
echo "RELAY: $OLD -> $NEW"
journalctl -u rathole -n 5 --no-pager
EOT
chmod +x /usr/local/bin/switch-relay
EOF

  # тест данных через туннель: временный TCP-сервер на BACKEND 127.0.0.1:8443 отдаёт 256 КБ
  cat > "$D/tuntest.py" <<'EOF'
import socket
s = socket.socket()
s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
s.bind(("127.0.0.1", 8443))
s.listen(1)
s.settimeout(40)
c, _ = s.accept()
c.recv(4096)
body = b"x" * 262144
c.sendall(b"HTTP/1.1 200 OK\r\nContent-Length: %d\r\nConnection: close\r\n\r\n" % len(body) + body)
c.close()
EOF
}

# ───────────────────────── RELAY: служебная команда switch-backend ─────────────────────────
install_switch_backend() {
  cat > /usr/local/bin/switch-backend <<'EOF'
#!/bin/bash
set -e
NEW="$1"; [ -z "$NEW" ] && { echo "usage: switch-backend НОВЫЙ_IP_BACKEND"; exit 1; }
F=/etc/ufw/before.rules
OLD=$(sed -n '/# BEGIN relay-setup-nat/,/# END relay-setup-nat/p' $F | grep -oP '(?<=--to-destination )[0-9.]+(?=:8443)' | head -1)
[ -z "$OLD" ] && { echo "старый BACKEND не найден в $F"; exit 1; }
sed -i "/# BEGIN relay-setup-nat/,/# END relay-setup-nat/s/$OLD/$NEW/g" $F
ufw route delete allow proto udp from any to $OLD port 8443 >/dev/null 2>&1 || true
ufw route allow proto udp from any to $NEW port 8443
ufw delete allow from $OLD to any port 2333 proto tcp >/dev/null 2>&1 || true
ufw allow from $NEW to any port 2333 proto tcp
ufw --force reload >/dev/null
[ -f /root/.relay-setup.conf ] && sed -i "s/^BACKEND_IP=.*/BACKEND_IP=$NEW/" /root/.relay-setup.conf
echo "BACKEND: $OLD -> $NEW"
iptables -t nat -S | grep -E 'DNAT|MASQUERADE' || true
EOF
  chmod +x /usr/local/bin/switch-backend
}

# ───────────────────────── сохранение настроек ─────────────────────────
load_conf() {
  [ -f "$CONF_FILE" ] || return 0
  # shellcheck disable=SC1090
  . "$CONF_FILE" 2>/dev/null || true
}

save_conf() {
  umask 077
  cat > "$CONF_FILE" <<EOF
RELAY_IP=$RELAY_IP
BACKEND_IP=$BACKEND_IP
BACKEND_PORT=$BACKEND_PORT
DOMAIN=$DOMAIN
EMAIL=$EMAIL
SECRET=$SECRET
EOF
  chmod 600 "$CONF_FILE"
}

cleanup() {
  [ -n "${TMPD:-}" ] && [ -d "$TMPD" ] && {
    [ -n "${SSH_OPTS+x}" ] && ssh "${SSH_OPTS[@]}" -O exit "root@${BACKEND_IP:-x}" >/dev/null 2>&1 || true
    rm -rf "$TMPD"
  }
  printf '%s' "$R"
}

# ───────────────────────── основной сценарий ─────────────────────────
main() {
  [ "$(id -u)" -eq 0 ] || { echo "Запустите от root: sudo bash $0"; exit 1; }
  mkdir -p "$(dirname "$LOG")"
  : > "$LOG"
  TMPD=$(mktemp -d /tmp/relay-setup.XXXXXX)
  trap cleanup EXIT
  trap 'echo; warn "прервано"; exit 130' INT TERM

  banner

  # ── автопроверки окружения (без вопросов)
  echo "${B}Проверка окружения${R}"
  thin
  # shellcheck disable=SC1091
  . /etc/os-release 2>/dev/null || true
  if [ "${ID:-}" = "ubuntu" ]; then
    if version_ge "${VERSION_ID:-0}" 22.04; then ok "ОС: ${PRETTY_NAME:-ubuntu}"; else die "нужна Ubuntu 22.04 или новее (найдена ${VERSION_ID:-?})"; fi
  elif [ "${ID:-}" = "debian" ]; then
    warn "ОС ${PRETTY_NAME:-debian}: скрипт проверен на Ubuntu 22.04+, на Debian 12+ должен работать"
  else
    warn "ОС ${PRETTY_NAME:-?}: скрипт рассчитан на Ubuntu 22.04+"
  fi
  ensure_tools || die "не удалось установить базовые утилиты (curl, dig, ssh, openssl)"
  RELAY_IP=$(detect_relay_ip)
  valid_ip "$RELAY_IP" || die "не удалось определить внешний IP этого сервера"
  ok "IP RELAY: $RELAY_IP"
  load_conf

  # ── вопросы
  echo
  echo "${B}Параметры${R}"
  thin
  while true; do
    ask BACKEND_IP "IP BACKEND" "${BACKEND_IP:-}"
    if [ "$BACKEND_IP" = "$RELAY_IP" ]; then fail "IP BACKEND совпадает с IP этого сервера"; BACKEND_IP=""; continue; fi
    valid_ip "$BACKEND_IP" && break
    fail "неверный IP"
    BACKEND_IP=""
  done
  while true; do
    ask BACKEND_PORT "SSH-порт BACKEND" "${BACKEND_PORT:-1119}"
    valid_port "$BACKEND_PORT" && break
    fail "неверный порт"
  done
  read_key
  while true; do
    ask DOMAIN "Домен панели (A-запись → IP RELAY)" "${DOMAIN:-}"
    valid_dom "$DOMAIN" && break
    fail "неверный домен"
    DOMAIN=""
  done
  EMAIL="admin@$DOMAIN"   # e-mail для Let's Encrypt: не спрашиваем

  # ── скрытая проверка DNS: молчит, если всё в порядке
  echo
  dns_check
  DNS_OK=$?

  SECRET="${SECRET:-$(openssl rand -hex 16)}"

  # ── сводка
  echo
  rule
  printf '  %sПлан установки%s\n' "$B" "$R"
  rule
  kv "RELAY" "$RELAY_IP  (rathole-server, ufw, UDP 8443 → BACKEND)"
  kv "BACKEND" "$BACKEND_IP  (SSH :$BACKEND_PORT)"
  kv "Domain" "$DOMAIN → https://$DOMAIN/<WebBasePath>"
  kv "E-mail" "$EMAIL"
  kv "RELAY ports" "443, 80, 8443/tcp → туннель; 2333 (только с BACKEND); 8443/udp → DNAT; прочее входящее закрывается (ufw)"
  kv "BACKEND ports" "входящие TCP 443/80/8443 закрываются; 8443/udp только от RELAY"
  kv "Tunnel" "rathole с TLS-транспортом (свой CA, SNI $DOMAIN); Noise не используется"
  kv "Panel" "3x-ui на 127.0.0.1:$PANEL_PORT (SQLite), nginx + Let's Encrypt"
  rule
  echo
  confirm "Всё верно, начать установку?" || { echo "  Отменено."; exit 0; }

  make_remote_scripts
  install_switch_backend

  # [1] SSH (первым: если GitHub недоступен с RELAY, rathole скачает BACKEND)
  section "Подключение к BACKEND"
  ssh_connect
  local bos
  bos=$(bk '. /etc/os-release; echo "$ID $VERSION_ID"' 2>>"$LOG")
  case "$bos" in
    ubuntu\ *) if version_ge "${bos#ubuntu }" 22.04; then ok "ОС BACKEND: Ubuntu ${bos#ubuntu }"; else die "BACKEND: нужна Ubuntu 22.04 или новее (найдена ${bos#ubuntu })"; fi ;;
    debian\ *) warn "ОС BACKEND: $bos (скрипт рассчитан на Ubuntu 22.04+)" ;;
    *) warn "ОС BACKEND не определена: ${bos:-?}" ;;
  esac

  # [2] подготовка RELAY
  section "RELAY: пакеты и rathole"
  step_run "Установка пакетов и rathole" relay_prepare || die "не удалось подготовить RELAY"

  # [3] rathole-server
  section "RELAY: rathole-server"
  local conflicts
  conflicts=$(relay_port_conflicts)
  [ -z "$conflicts" ] || die "на RELAY заняты порты:$conflicts (остановите nginx/apache/другие сервисы на этих портах)"
  step_run "TLS: свой CA и сертификат для $DOMAIN" relay_tls_setup || die "не удалось создать TLS-сертификат туннеля"
  step_run "Конфиг и запуск rathole-server (TLS)" relay_rathole_server || die "rathole-server не запустился"

  # [4] firewall + UDP
  section "RELAY: firewall и пересылка UDP 8443"
  step_run "ufw, форвардинг, NAT для 8443/udp" relay_firewall || die "не удалось настроить firewall RELAY"

  # [5] BACKEND: пакеты
  section "BACKEND: пакеты и обновление системы"
  step_run "apt update/upgrade, nginx, certbot, ufw" rscript "$TMPD/pkgs.sh" || die "не удалось подготовить BACKEND"

  # [6] rathole-client
  section "BACKEND: rathole-client"
  step_run "Установка rathole и подключение к RELAY (TLS)" backend_rathole || die "rathole-client не запустился (проверьте TLS-сертификат и порт 2333)"

  # [7] проверка туннеля
  section "Проверка туннеля"
  local i listening=0
  for i in 1 2 3 4 5 6 7 8 9 10; do
    if [ "$(ss -tlnH 2>/dev/null | grep -cE ':(443|80|8443) ')" -ge 3 ]; then listening=1; break; fi
    sleep 1
  done
  if [ $listening -eq 1 ]; then ok "RELAY слушает 443, 80, 8443 — BACKEND подключился"; else die "BACKEND не подключился к rathole-server (проверьте порт 2333 и секрет)"; fi
  bk "cat > /tmp/tuntest.py" < "$TMPD/tuntest.py" 2>>"$LOG"
  bk "nohup timeout 45 python3 /tmp/tuntest.py >/dev/null 2>&1 </dev/null &" >>"$LOG" 2>&1
  sleep 2
  local got
  got=$(curl -s --max-time 25 http://127.0.0.1:8443/ -o /dev/null -w '%{size_download}' 2>/dev/null || echo 0)
  if [ "${got:-0}" -ge 262144 ]; then
    ok "поток данных через туннель: 256 КБ без зависаний"
  elif [ "${got:-0}" -gt 0 ]; then
    warn "через туннель пришло только $((got / 1024)) КБ из 256 — возможна заморозка TCP на участке BACKEND→RELAY (см. раздел «Разбор неполадок» гайда)"
  else
    warn "тест потока пропущен (порт 8443 на BACKEND занят или туннель не отвечает)"
  fi
  bk "rm -f /tmp/tuntest.py; pkill -f tuntest.py || true" >>"$LOG" 2>&1 || true

  # [8] 3x-ui
  section "BACKEND: 3x-ui"
  step_run "Установка 3x-ui (SQLite, порт $PANEL_PORT, панель на 127.0.0.1)" rscript "$TMPD/xui.sh" "$PANEL_PORT" || die "3x-ui не установился"
  local res xu xp xw xt
  res=$(bk 'cat /etc/x-ui/install-result.env' 2>>"$LOG")
  getv() { printf '%s\n' "$res" | sed -n "s/^$1=//p" | head -1 | sed "s/^'//; s/'$//"; }
  xu=$(getv XUI_USERNAME); xp=$(getv XUI_PASSWORD); xw=$(getv XUI_WEB_BASE_PATH); xt=$(getv XUI_API_TOKEN)
  if ! { [ -n "$xu" ] && [ -n "$xp" ] && [ -n "$xw" ]; }; then
    warn "файл данных установщика не найден (панель уже была установлена?) — задаю новые данные входа"
    xu=$(openssl rand -hex 5); xp=$(openssl rand -hex 5); xw=$(openssl rand -hex 9)
    bk "/usr/local/x-ui/x-ui setting -username '$xu' -password '$xp' -port $PANEL_PORT -webBasePath '$xw' -listenIP 127.0.0.1 && systemctl restart x-ui" >>"$LOG" 2>&1 || die "не удалось задать данные панели"
    xt=$(bk "/usr/local/x-ui/x-ui setting -getApiToken" 2>>"$LOG" | grep -Eo 'apiToken: .+' | awk '{print $2}')
  fi
  echo
  rule
  printf '  %sPanel Installation Complete!%s\n' "$GRN" "$R"
  rule
  printf '%sUsername:    %s%s\n' "$GRN" "$xu" "$R"
  printf '%sPassword:    %s%s\n' "$GRN" "$xp" "$R"
  printf '%sPort:        %s%s\n' "$GRN" "$PANEL_PORT" "$R"
  printf '%sWebBasePath: %s%s\n' "$GRN" "$xw" "$R"
  printf '%sDatabase:    SQLite (/etc/x-ui/x-ui.db)%s\n' "$GRN" "$R"
  printf '%sAccess URL:  http://127.0.0.1:%s/%s%s\n' "$GRN" "$PANEL_PORT" "$xw" "$R"
  printf '%sAPI Token:   %s%s\n' "$GRN" "${xt:-—}" "$R"
  rule

  # [9] nginx временный
  section "BACKEND: nginx (временный конфиг)"
  step_run "nginx: порт 80 → панель" rscript "$TMPD/nginx-temp.sh" "$DOMAIN" || die "nginx не настроился"
  local code
  code=$(curl -s -o /dev/null --max-time 15 -w '%{http_code}' -H "Host: $DOMAIN" http://127.0.0.1:80/ 2>/dev/null)
  if [ "$code" != "000" ] && [ -n "$code" ]; then ok "порт 80 доходит до BACKEND через туннель (HTTP $code)"; else warn "порт 80 через туннель не отвечает — сертификат, скорее всего, не выпустится"; fi

  # [10] сертификат
  section "Сертификат Let's Encrypt"
  CERT_OK=0
  if [ "$DNS_OK" -ne 0 ]; then warn "DNS не подтверждён — попытка выпуска может не удаться"; fi
  while true; do
    if step_run "certbot --standalone для $DOMAIN" rscript "$TMPD/cert.sh" "$DOMAIN" "$EMAIL"; then CERT_OK=1; break; fi
    warn "не удалось выпустить сертификат (DNS ещё не разошёлся? порт 80 недоступен?)"
    confirm "Повторить?" || break
  done

  # [11] nginx финальный
  section "BACKEND: nginx (финальный конфиг) и автопродление"
  if [ $CERT_OK -eq 1 ]; then
    step_run "nginx с сертификатом, /waw/, хуки продления" rscript "$TMPD/nginx-final.sh" "$DOMAIN" || die "не удалось включить финальный конфиг nginx"
  else
    warn "без сертификата оставлен временный конфиг: панель доступна по http://$DOMAIN/$xw"
  fi

  # [12] firewall BACKEND
  section "BACKEND: firewall"
  step_run "ufw: SSH сохранён, TCP 443/80/8443 закрыты, 8443/udp только от RELAY" rscript "$TMPD/ufw-backend.sh" "$RELAY_IP" || die "не удалось настроить firewall BACKEND"

  # [13] итог
  section "Проверка связки и служебные команды"
  step_run "Установка switch-relay на BACKEND" rscript "$TMPD/helper-backend.sh" || warn "switch-relay не установлен"
  ok "switch-backend установлен на RELAY"
  save_conf
  ok "настройки сохранены: $CONF_FILE"
  local final_url final_code
  if [ $CERT_OK -eq 1 ]; then
    final_url="https://$DOMAIN/$xw"
    final_code=$(curl -s -o /dev/null --max-time 15 -w '%{http_code}' --resolve "$DOMAIN:443:127.0.0.1" "$final_url" 2>/dev/null)
    if [ "$final_code" = "200" ]; then ok "HTTPS через туннель: $final_url → HTTP 200 (сертификат валиден)"; else warn "HTTPS-проверка вернула HTTP ${final_code:-000}: проверьте nginx и сертификат на BACKEND"; fi
  else
    final_url="http://$DOMAIN/$xw"
  fi

  # UDP-предупреждение: у BACKEND нет собственного IPv4?
  if ! bk "ip -4 -o addr show scope global | awk '{print \$4}' | cut -d/ -f1 | grep -qx '$BACKEND_IP'" 2>>"$LOG"; then
    warn "IP $BACKEND_IP не назначен на интерфейсе BACKEND (общий IP/NAT): пересылка UDP 8443 на него работать не будет — Hysteria2 через RELAY недоступна"
  fi

  {
    echo "RELAY·BACKEND Tunnel Setup v$VERSION — $(date '+%F %T')"
    echo "RELAY:        $RELAY_IP"
    echo "BACKEND:      $BACKEND_IP (SSH :$BACKEND_PORT)"
    echo "Domain:       $DOMAIN"
    echo "Panel URL:    $final_url"
    echo "Username:     $xu"
    echo "Password:     $xp"
    echo "API Token:    ${xt:-—}"
    echo "rathole key:  $SECRET"
  } > "$REPORT_FILE"
  chmod 600 "$REPORT_FILE"

  echo
  rule
  printf '  %sДоступ к панели%s\n' "$GRN" "$R"
  rule
  printf '%s%s%s\n' "$B" "$final_url" "$R"
  printf '%sUsername:    %s%s\n' "$GRN" "$xu" "$R"
  printf '%sPassword:    %s%s\n' "$GRN" "$xp" "$R"
  rule
  echo "  ${DIM}Отчёт с этими данными: $REPORT_FILE (права 600)${R}"
  echo "  ${DIM}Лог установки:         $LOG${R}"
  echo "  ${DIM}Замена серверов:       switch-relay (на BACKEND), switch-backend (на RELAY)${R}"
  echo
  echo "  ${B}Дальше — в панели:${R}"
  echo "   • VLESS Reality: Listen IP 127.0.0.1, порт 8443, пользовательский адрес $DOMAIN"
  echo "   • Hysteria2: Listen пусто, порт 8443/udp, SNI $DOMAIN, сертификат /etc/letsencrypt/live/$DOMAIN/"
  echo "   • Подписка: Subscribe URI /waw/, URI обратного прокси https://$DOMAIN/waw/"
  echo
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  main "$@"
fi
