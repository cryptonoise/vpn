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
VERSION="1.7.0"
NAME="RELAY·BACKEND Tunnel Setup"

set -u
set -o pipefail
export LC_ALL=C.UTF-8   # одинаковая работа с кириллицей независимо от локали сервера

# ───────────────────────── пути (переопределяются для тестов) ─────────────────────────
UFW_BEFORE="${UFW_BEFORE:-/etc/ufw/before.rules}"
UFW_SYSCTL="${UFW_SYSCTL:-/etc/ufw/sysctl.conf}"
CONF_FILE="${CONF_FILE:-/root/.relay-setup.conf}"
REPORT_FILE="${REPORT_FILE:-/root/relay-setup-report.txt}"
LOG="${LOG:-/var/log/relay-setup.log}"
TLS_DIR="${TLS_DIR:-/etc/rathole/tls}"
MARKER_FILE="${MARKER_FILE:-/root/.relay-setup.installed}"
PANEL_PORT=999
TOTAL=14
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
  rd -r -p "  Нажмите Enter, чтобы начать." _
  echo
}

# ───────────────────────── ввод ─────────────────────────
# rd — чтение с терминала (даже если stdin — пайп); при закрытом вводе скрипт завершается,
# а не крутится в бесконечном цикле
rd() {
  local rc
  if ( : < /dev/tty ) 2>/dev/null; then read "$@" < /dev/tty; else read "$@"; fi
  rc=$?
  if [ $rc -ne 0 ]; then
    echo
    die "ввод недоступен (терминал закрыт). Запустите скрипт в интерактивной сессии: bash relay-setup.sh"
  fi
}

ask() {  # ask VAR "Вопрос" "по умолчанию"
  local __v="$1" q="$2" d="${3:-}" a
  if [ -n "$d" ]; then
    rd -r -p "${B}?${R} $q ${DIM}[$d]${R}: " a
    a="${a:-$d}"
  else
    rd -r -p "${B}?${R} $q: " a
  fi
  printf -v "$__v" '%s' "$a"
}

confirm() {  # Enter / y = да, n = нет
  local a
  while true; do
    rd -r -p "${B}?${R} $1 ${DIM}[Enter или y — да / n — нет]${R}: " a
    case "${a:-y}" in
      y | Y | yes | YES | д | Д) return 0 ;;
      n | N | no | NO | н | Н | нет) return 1 ;;
      *) printf '  %sВведите Enter или y (да) / n (нет)%s\n' "$DIM" "$R" ;;
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

# сетевые твики: BBR, буферы TCP/UDP, MTU probing и др. (применяется на RELAY и BACKEND)
tune_network() {
  local f=/etc/sysctl.d/99-relay-network-tuning.conf
  modprobe tcp_bbr 2>/dev/null || true
  echo tcp_bbr > /etc/modules-load.d/relay-bbr.conf
  {
    echo "# relay-setup: сетевые твики"
    echo "net.core.default_qdisc=fq"
    if grep -qw bbr /proc/sys/net/ipv4/tcp_available_congestion_control 2>/dev/null; then echo "net.ipv4.tcp_congestion_control=bbr"; fi
    printf '%s\n' \
      "net.core.rmem_max=33554432" \
      "net.core.wmem_max=33554432" \
      "net.ipv4.tcp_rmem=4096 262144 33554432" \
      "net.ipv4.tcp_wmem=4096 262144 33554432" \
      "net.ipv4.udp_rmem_min=16384" \
      "net.ipv4.udp_wmem_min=16384" \
      "net.ipv4.tcp_mtu_probing=1" \
      "net.ipv4.tcp_slow_start_after_idle=0" \
      "net.ipv4.tcp_fastopen=3" \
      "net.core.netdev_max_backlog=16384" \
      "net.core.somaxconn=4096" \
      "net.ipv4.tcp_max_syn_backlog=8192" \
      "net.ipv4.ip_local_port_range=10240 65535" \
      "net.ipv4.tcp_keepalive_time=300" \
      "net.ipv4.tcp_keepalive_intvl=30" \
      "net.ipv4.tcp_keepalive_probes=5" \
      "fs.file-max=1048576"
    if [ -e /proc/sys/net/netfilter/nf_conntrack_max ]; then echo "net.netfilter.nf_conntrack_max=262144"; fi
  } > "$f"
  sysctl -q -p "$f" >/dev/null 2>&1 || sysctl --system >/dev/null 2>&1 || true
  systemctl try-restart rathole >/dev/null 2>&1 || true
  return 0
}

# ───────────────────────── метка установки ─────────────────────────
write_marker() {  # write_marker статус (in-progress | done)
  umask 077
  cat > "$MARKER_FILE" <<EOF
STATUS=$1
INSTALLED_AT=$(date '+%F %T')
VERSION=$VERSION
KIND=${INSTALL_KIND:-relay}
RELAY_IP=${RELAY_IP:-}
BACKEND_IP=${BACKEND_IP:-}
BACKEND_PORT=${BACKEND_PORT:-}
DOMAIN=${DOMAIN:-}
EOF
}
marker_get() { sed -n "s/^$1=//p" "$MARKER_FILE" 2>/dev/null | head -n1; }

menu() {
  local has=0 c k
  [ -f "$MARKER_FILE" ] && has=1
  echo
  echo "${B}Что делаем?${R}"
  thin
  if [ $has -eq 1 ]; then
    k=$(marker_get KIND); k="${k:-relay}"
    info "найдена метка установки: $(marker_get INSTALLED_AT), статус: $(marker_get STATUS), режим: $k, сервер $(marker_get BACKEND_IP), домен $(marker_get DOMAIN)"
  fi
  echo "  ${B}1${R}. Установить и настроить Backend сервер с 3X-UI панелью (без relay)"
  echo "  ${B}2${R}. Установить и настроить Relay + Backend сервер с 3X-UI панелью"
  echo "  ${B}3${R}. Протестировать BACKEND сервер"
  [ $has -eq 1 ] && echo "  ${B}4${R}. Отменить установку (удалить всё)"
  while true; do
    rd -r -p "${B}?${R} Выберите вариант: " c
    case "$c" in
      1) MODE="install_backend"; return 0 ;;
      2) MODE="install_relay"; return 0 ;;
      3) MODE="test"; return 0 ;;
      4) if [ $has -eq 1 ]; then MODE="uninstall"; return 0; fi; fail "вариант 4 доступен только после установки" ;;
      *) if [ $has -eq 1 ]; then fail "введите 1, 2, 3 или 4"; else fail "введите 1, 2 или 3"; fi ;;
    esac
  done
}

# ───────────────────────── удаление установки ─────────────────────────
relay_uninstall() {
  local dest ip
  dest=$(sed -n '/# BEGIN relay-setup-nat/,/# END relay-setup-nat/p' "$UFW_BEFORE" 2>/dev/null | grep -oP '(?<=--to-destination )[0-9.]+(?=:8443)' | head -n1)
  systemctl disable --now rathole >/dev/null 2>&1 || true
  rm -f /etc/systemd/system/rathole.service /usr/local/bin/rathole /usr/local/bin/switch-backend
  rm -rf /etc/rathole
  systemctl daemon-reload
  for ip in $(ufw status 2>/dev/null | awk '/2333\/tcp/ { print $NF }' | grep -E '^[0-9.]+$'); do
    ufw delete allow from "$ip" to any port 2333 proto tcp >/dev/null 2>&1 || true
  done
  for ip in 443/tcp 80/tcp 8443/tcp 8443/udp; do ufw delete allow "$ip" >/dev/null 2>&1 || true; done
  [ -n "$dest" ] && { ufw route delete allow proto udp from any to "$dest" port 8443 >/dev/null 2>&1 || true; }
  [ -f "$UFW_BEFORE" ] && sed -i '/^# BEGIN relay-setup-nat$/,/^# END relay-setup-nat$/d' "$UFW_BEFORE"
  rm -f /etc/sysctl.d/99-relay-forward.conf /etc/sysctl.d/99-relay-network-tuning.conf /etc/modules-load.d/relay-bbr.conf
  ufw --force reload >/dev/null 2>&1 || true
  rm -f "$CONF_FILE" "$REPORT_FILE" "$MARKER_FILE"
}

do_uninstall() {
  STEP=0; TOTAL=3
  local kind
  kind=$(marker_get KIND); kind="${kind:-relay}"
  echo
  echo "${B}Удаление установки${R}"
  thin
  if [ "$kind" = "backend" ]; then
    info "BACKEND (режим без relay): правила ufw (80, 443, 8443), служебная команда sync-sub-path, сетевые твики"
  else
    info "RELAY: туннель rathole, правила ufw (2333, 80, 443, 8443), NAT для UDP, служебные команды, сетевые твики"
    info "BACKEND: rathole-client, правило 8443/udp, switch-relay, sync-sub-path, сетевые твики"
  fi
  confirm "Удалить эти настройки?" || { echo "  Отменено."; return 1; }
  local rm_xui=0 rm_web=0 reach=0 direct=0
  [ "$kind" = "backend" ] && direct=1
  ask_backend
  if [ "${LOCAL_BACKEND:-0}" = 1 ]; then
    reach=1
  else
    ssh_opts
    if ssh "${SSH_OPTS[@]}" -o BatchMode=yes "root@$BACKEND_IP" true >/dev/null 2>"$TMPD/ssh.err"; then
      reach=1
      ok "SSH: root@$BACKEND_IP:$BACKEND_PORT"
    else
      fail "BACKEND недоступен: $(tail -n1 "$TMPD/ssh.err")"
      confirm "Удалить только настройки RELAY (BACKEND останется как есть)?" || { echo "  Отменено."; return 1; }
    fi
  fi
  if [ $reach -eq 1 ]; then
    confirm "Удалить на BACKEND также 3x-ui (панель, пользователи, инбаунды)?" && rm_xui=1
    confirm "Удалить на BACKEND также конфиг nginx и сертификат домена ${DOMAIN:-$(marker_get DOMAIN)}?" && rm_web=1
  fi
  make_remote_scripts
  section "BACKEND"
  if [ $reach -eq 1 ]; then
    step_run "Удаление настроек, правил и служебных команд" rscript "$TMPD/uninstall-backend.sh" "${RELAY_IP:-$(marker_get RELAY_IP)}" "${DOMAIN:-$(marker_get DOMAIN)}" "$rm_xui" "$rm_web" "$direct" || warn "часть действий на BACKEND не выполнена (см. лог)"
  else
    warn "пропущено: BACKEND недоступен"
  fi
  section "RELAY"
  if [ "$kind" = "backend" ]; then
    info "relay в этом режиме не использовался"
    rm -f "$CONF_FILE" "$REPORT_FILE" "$MARKER_FILE"
  else
    step_run "Удаление rathole, правил ufw, NAT и настроек сети" relay_uninstall || warn "часть действий на RELAY не выполнена (см. лог)"
  fi
  section "Готово"
  ok "метка установки удалена"
  [ $reach -eq 1 ] && [ $rm_xui -eq 0 ] && [ "$kind" != "backend" ] && info "панель 3x-ui на BACKEND оставлена (порты 80/443 на BACKEND закрыты ufw — при необходимости откройте: ufw allow 443/tcp)"
  return 0
}

# ───────────────────────── тест BACKEND (iperf3) ─────────────────────────
iperf_run() {  # iperf_run имя [опции iperf3]
  local name="$1"; shift
  timeout 45 iperf3 -c "$BACKEND_IP" -p 5201 -4 -t 8 --connect-timeout 5000 -J "$@" > "$TMPD/iperf-$name.json" 2>>"$LOG" || true
  { echo "--- iperf3 $name:"; head -c 1500 "$TMPD/iperf-$name.json"; echo; } >> "$LOG"
}

iperf_parse() {  # → "Мбит/с байт retr ошибка"
  python3 - "$1" <<'PY'
import json, sys
try:
    d = json.load(open(sys.argv[1]))
except Exception:
    print("0 0 0 нет ответа от iperf3 (таймаут или запуск не удался)")
    sys.exit(0)
err = str(d.get("error", "")).replace("\n", " ")[:90]
e = d.get("end") or {}
r = e.get("sum_received") or {}
t = e.get("sum_sent") or {}
if not e and not err:
    err = "iperf3 завершился без данных"
print(int(r.get("bits_per_second", 0) / 1e6), int(r.get("bytes", 0)), int(t.get("retransmits", 0)), err)
PY
}

res_line() {  # res_line статус(ok|warn|fail|info) "название" "значение"
  local ic
  case "$1" in ok) ic="${GRN}✔${R}" ;; warn) ic="${YLW}▲${R}" ;; fail) ic="${RED}✖${R}" ;; *) ic="${BLU}•${R}" ;; esac
  local n=$((34 - ${#2}))
  [ $n -lt 1 ] && n=1
  printf '  %s %s%s%*s%s %s\n' "$ic" "$DIM" "$2" "$n" "" "$R" "$3"
}

# оценка одного TCP-теста (массивы problems/warns — из run_test)
tcp_line() {  # tcp_line "подпись" Мбит/с байт retr|- ошибка секунд порт_недоступен [тихо]
  local label="$1" mb="$2" by="$3" rt="$4" er="$5" secs="$6" bad="$7" quiet="${8:-0}" extra=""
  [ "$rt" != "-" ] && extra=", retr ${rt}"
  if [ "$bad" = 1 ]; then
    res_line fail "$label" "не выполнен: тестовый порт недоступен"
  elif [ "$er" = "STALL" ]; then
    if [[ "$label" == *отдача* ]]; then
      res_line fail "$label" "данные перестали уходить (поток встал)"
    else
      res_line fail "$label" "получено $((by / 1024)) КБ, затем данные перестали идти"
    fi
    [ "$quiet" = 1 ] || problems+=("$label: поток встаёт (получено ~$((by / 1024)) КБ)")
  elif [ -n "$er" ] && [ "$by" -lt 200000 ]; then
    res_line fail "$label" "не выполнен: $er"
    [ "$quiet" = 1 ] || problems+=("$label: тест не выполнен — $er")
  elif [ "$by" -lt 200000 ] || [ "$mb" -lt 1 ]; then
    res_line fail "$label" "получено $((by / 1024)) КБ за ${secs} с — поток замерзает"
    [ "$quiet" = 1 ] || problems+=("$label: поток замерзает после ~$((by / 1024)) КБ")
  elif [ "$mb" -lt 100 ]; then
    res_line warn "$label" "${mb} Мбит/с${extra}"
    [ "$quiet" = 1 ] || warns+=("$label: скорость ниже 100 Мбит/с")
  else
    res_line ok "$label" "${mb} Мбит/с${extra}"
  fi
}

# сырой TCP без TLS (iperf3): справочно — заморозка здесь не означает, что VPN не работает
raw_line() {  # raw_line "подпись" Мбит/с байт retr ошибка
  local label="$1" mb="$2" by="$3" rt="$4" er="$5"
  if [ "${PORT_BAD:-0}" = 1 ]; then
    res_line info "$label" "пропущен: порт 5201 недоступен"
  elif [ -n "$er" ] && [ "$by" -lt 200000 ]; then
    res_line info "$label" "не выполнен: $er"
  elif [ "$by" -lt 200000 ] || [ "$mb" -lt 1 ]; then
    RAW_FROZEN=1
    res_line warn "$label" "режется: получено $((by / 1024)) КБ за 8 с (справочно)"
  else
    res_line ok "$label" "${mb} Мбит/с, retr ${rt}"
  fi
}

probe() {  # probe имя вид порт аргументы...
  local name="$1" kind="$2" port="$3"; shift 3
  timeout 60 python3 "$TMPD/tlstest-client.py" "$kind" "$BACKEND_IP" "$port" "$@" > "$TMPD/pr-$name.txt" 2>>"$LOG" || true
  echo "--- probe $name ($kind :$port $*): $(cat "$TMPD/pr-$name.txt" 2>/dev/null)" >> "$LOG"
}

probe_if() {  # probe_if имя вид порт ... — только если порт доступен
  [ "${PS[$3]:-0}" = 1 ] || return 0
  probe "$@"
}

pr_get() {  # → "Мбит/с байт ошибка"
  local f="$TMPD/pr-$1.txt"
  if [ -s "$f" ]; then head -n1 "$f"; else echo "0 0 нет ответа (таймаут или запуск не удался)"; fi
}

pr_state() {  # → 1 поток идёт, 0 встал/ошибка, -1 порт недоступен
  local name="$1" port="$2" a b e
  if [ "${PS[$port]:-0}" != 1 ]; then echo -1; return; fi
  read -r a b e <<< "$(pr_get "$name")"
  if [ -z "$e" ] && [ "${b:-0}" -ge 200000 ] && [ "${a:-0}" -ge 1 ]; then echo 1; else echo 0; fi
}

pr_line() {  # pr_line имя "подпись" порт секунд [тихо]
  local n="$1" label="$2" port="$3" secs="$4" q="${5:-1}" mb by er
  if [ "${PS[$port]:-0}" != 1 ]; then res_line info "$label" "пропущен: порт $port недоступен"; return 0; fi
  read -r mb by er <<< "$(pr_get "$n")"
  tcp_line "$label" "$mb" "$by" "-" "$er" "$secs" 0 "$q"
}

# варианты, которые можно гнать параллельно (определяют, ОТ ЧЕГО зависит блокировка)
probe_batch() {
  local w="dl.google.com"
  probe_if ya tls 8444 yandex.ru D 1 4 &
  probe_if vk tls 8444 vk.com D 1 4 &
  probe_if ms tls 8444 www.microsoft.com D 1 4 &
  probe_if ns tls 8444 - D 1 4 &
  [ -n "$SNI_DOM" ] && probe_if dm tls 8444 "$SNI_DOM" D 1 4 &
  probe_if gi tls 8444 "$w" D 1 4 0 8 &
  probe_if t12 tls 8445 "$w" D 1 4 &
  probe_if pa tls 2087 "$w" D 1 4 &
  probe_if pb tls 9443 "$w" D 1 4 &
  probe_if pc tls 4443 "$w" D 1 4 &
  probe_if r8446 raw 8446 - D 1 4 &
  probe_if h8447 http 8447 "$w" D 1 4 &
  [ -n "$SNI_DOM" ] && probe_if h8447d http 8447 "$SNI_DOM" D 1 4 &
  wait
}

# контроль: скачивание с RELAY с других зарубежных сайтов (нагрузки на VPN нет)
ctl_run() {  # ctl_run имя URL [опции curl]
  curl -s --max-time 8 "${@:3}" -o /dev/null -w '%{size_download} %{http_code}' "$2" > "$TMPD/ctl-$1.txt" 2>>"$LOG" || true
}
ctl_batch() {
  ctl_run cf "https://speed.cloudflare.com/__down?bytes=4000000" &
  ctl_run hz "https://speed.hetzner.de/100MB.bin" -r 0-3999999 &
  ctl_run ovh "https://proof.ovh.net/files/10Mb.dat" -r 0-3999999 &
  ctl_run gg "https://dl.google.com/linux/direct/google-chrome-stable_current_amd64.deb" -r 0-3999999 &
  wait
}
ctl_line() {  # ctl_line имя "подпись"
  local sz code
  read -r sz code < "$TMPD/ctl-$1.txt" 2>/dev/null || { sz=0; code=000; }
  sz="${sz:-0}"; code="${code:-000}"
  if [ "$sz" -ge 1000000 ]; then res_line ok "$2" "получено $((sz / 1048576)) МБ за 8 с"
  elif [ "$sz" -ge 200000 ]; then res_line warn "$2" "получено $((sz / 1024)) КБ за 8 с (медленно)"
  elif [ "$code" = "000" ] && [ "$sz" -eq 0 ]; then res_line fail "$2" "нет ответа (соединение не установилось или встало до заголовков)"
  else res_line fail "$2" "получено $((sz / 1024)) КБ (код $code) — режется"
  fi
}

asn_info() {  # "AS12345 название"
  local rev a n
  rev=$(echo "$BACKEND_IP" | awk -F. '{ print $4"."$3"."$2"."$1 }')
  a=$(dig +short TXT "$rev.origin.asn.cymru.com" @8.8.8.8 2>/dev/null | head -n1 | tr -d '"' | awk -F'|' '{ print $1 }' | awk '{ print $1 }')
  [ -n "$a" ] || return 0
  n=$(dig +short TXT "AS${a}.asn.cymru.com" @8.8.8.8 2>/dev/null | head -n1 | tr -d '"' | awk -F'|' '{ print $NF }' | sed 's/^ *//')
  echo "AS${a} ${n}"
}

joinl() { local out="" x; for x in "$@"; do out="${out:+$out; }$x"; done; echo "$out"; }

# наибольший размер пакета, проходящий без фрагментации (MTU пути)
mtu_probe() {
  local sz
  : > "$TMPD/mtu.txt"
  for sz in 1472 1452 1432 1412 1392 1372 1352 1300 1200; do
    if ping -c 1 -W 1 -M "do" -s "$sz" -q "$BACKEND_IP" >/dev/null 2>&1; then
      echo $((sz + 28)) > "$TMPD/mtu.txt"
      return 0
    fi
  done
  echo 0 > "$TMPD/mtu.txt"
}

run_test() {
  STEP=0; TOTAL=6
  echo
  echo "${B}Тест BACKEND: блокировки и скорость${R}"
  thin
  info "тест идёт на свободных портах (8444, 2087, 9443, 4443, 8445–8448, 5201) и не трогает 443, 8443, 999 и работу VPN"
  ask_backend
  [ "${LOCAL_BACKEND:-0}" = 1 ] && die "для теста IP BACKEND должен отличаться от IP этого сервера (тест идёт между двумя серверами)"
  make_remote_scripts

  section "Подключение к BACKEND"
  ssh_connect

  section "Подготовка: iperf3 и сетевые настройки"
  if command -v iperf3 >/dev/null 2>&1; then
    ok "iperf3 на RELAY уже установлен"
  else
    step_run "iperf3 на RELAY" bash -c 'export DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=a; apt-get -o DPkg::Lock::Timeout=300 update -y && apt-get -o DPkg::Lock::Timeout=300 install -y iperf3' || die "не удалось установить iperf3 на RELAY"
  fi
  if bk 'command -v iperf3 >/dev/null 2>&1' 2>>"$LOG"; then
    ok "iperf3 на BACKEND уже установлен"
  else
    step_run "iperf3 на BACKEND" rscript "$TMPD/iperf-install.sh" || die "не удалось установить iperf3 на BACKEND"
  fi
  # BBR/fq нужны для честного измерения — применяем скрыто на обоих серверах
  tune_network >>"$LOG" 2>&1
  rscript "$TMPD/tune.sh" >>"$LOG" 2>&1 || true

  section "Тестовые серверы на BACKEND"
  IPERF_STARTED=1
  step_run "iperf3 -s (порт 5201 открыт только для RELAY)" rscript "$TMPD/iperf-server.sh" "$RELAY_IP" || die "не удалось запустить iperf3-сервер на BACKEND"
  step_run "тестовый сервер: TLS 1.3/1.2, HTTP, сырой TCP, UDP (порты открыты только для RELAY)" rscript "$TMPD/tlstest-start.sh" "$RELAY_IP" || die "не удалось запустить тестовый сервер на BACKEND"
  local -A PS=()
  local pp bound unavailable="" busy=""
  bound=$(bk 'cat /run/relay-test.ports' 2>>"$LOG")
  for pp in 5201 8444 2087 9443 4443 8445 8446 8447; do
    if [ "$pp" != 5201 ] && ! grep -q ":$pp:" <<< "$bound"; then busy="$busy $pp"; PS[$pp]=0; continue; fi
    if timeout 4 bash -c ">/dev/tcp/$BACKEND_IP/$pp" 2>/dev/null; then PS[$pp]=1; else PS[$pp]=0; unavailable="$unavailable $pp"; fi
  done
  PS[8448]=1
  ok "тестовые порты, доступные с RELAY:$(for pp in 5201 8444 2087 9443 4443 8445 8446 8447; do [ "${PS[$pp]}" = 1 ] && printf ' %s' "$pp"; done) (+ UDP 8448)"
  [ -n "$unavailable" ] && warn "недоступны с RELAY (firewall хостера?):$unavailable"
  [ -n "$busy" ] && info "заняты на BACKEND, пропущены:$busy"

  local SNI_W="dl.google.com" SNI_DOM="${DOMAIN:-}"
  [ -n "$SNI_DOM" ] || SNI_DOM=$(marker_get DOMAIN)

  section "Измерения (RELAY → BACKEND, напрямую, без туннеля)"
  step_run "ping, 10 пакетов" bash -c "ping -c 10 -i 0.3 -q '$BACKEND_IP' > '$TMPD/ping.txt' 2>&1 || true"
  step_run "MTU пути (ping с запретом фрагментации)" mtu_probe
  if [ "${PS[5201]}" = 1 ]; then
    step_run "сырой TCP, iperf3, 1 поток (8 с)" iperf_run p1 -P 1
    step_run "сырой TCP, iperf3, MSS 1200 (8 с)" iperf_run pm -P 1 -M 1200
  fi
  if [ "${PS[8444]}" = 1 ]; then
    step_run "TLS, SNI $SNI_W, 1 поток (6 с)" probe g1 tls 8444 "$SNI_W" D 1 6
    step_run "TLS, SNI $SNI_W, MSS 1200 (6 с)" probe gm tls 8444 "$SNI_W" D 1 6 1200
  fi
  step_run "варианты: SNI, порты, TLS 1.2, HTTP, сырой TCP, пауза (параллельно)" probe_batch
  if [ "$(pr_state g1 8444)" = 1 ] || [ "$(pr_state gm 8444)" = 1 ]; then
    step_run "TLS, SNI $SNI_W, 4 потока (6 с)" probe g4 tls 8444 "$SNI_W" D 4 6
    step_run "TLS, SNI $SNI_W, отдача на BACKEND (6 с)" probe gu tls 8444 "$SNI_W" U 1 6
  fi
  step_run "UDP: эхо (20 пакетов)" probe uecho udp-echo 8448
  step_run "UDP: поток ~48 Мбит/с (4 с)" probe ublast udp-blast 8448 4
  step_run "контроль: скачивание с RELAY с Cloudflare, Hetzner, OVH, Google (8 с)" ctl_batch

  section "Сетевые параметры"
  local cc_r cc_b qd_r qd_b dev_r dev_b mtu_r mtu_b
  cc_r=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null)
  qd_r=$(sysctl -n net.core.default_qdisc 2>/dev/null)
  cc_b=$(bk 'sysctl -n net.ipv4.tcp_congestion_control' 2>>"$LOG")
  qd_b=$(bk 'sysctl -n net.core.default_qdisc' 2>>"$LOG")
  ok "RELAY: ${cc_r:-?} / ${qd_r:-?}   BACKEND: ${cc_b:-?} / ${qd_b:-?}"
  dev_r=$(ip route get "$BACKEND_IP" 2>/dev/null | grep -oP 'dev \K\S+' | head -n1)
  mtu_r=$(cat "/sys/class/net/${dev_r:-none}/mtu" 2>/dev/null)
  dev_b=$(bk "ip route get $RELAY_IP | grep -oP 'dev \K\S+' | head -n1" 2>>"$LOG")
  mtu_b=$(bk "cat /sys/class/net/${dev_b:-none}/mtu" 2>>"$LOG")
  ok "MTU интерфейсов: RELAY ${dev_r:-?}=${mtu_r:-?}, BACKEND ${dev_b:-?}=${mtu_b:-?}"

  section "Результаты"
  iperf_stop
  local p1 p1b p1r p1e pm pmb pmr pme g1 g1b g1e gm gmb gme g4 g4b g4e gu gub gue loss rtt pmtu asn
  read -r p1 p1b p1r p1e <<< "$(iperf_parse "$TMPD/iperf-p1.json")"
  read -r pm pmb pmr pme <<< "$(iperf_parse "$TMPD/iperf-pm.json")"
  read -r g1 g1b g1e <<< "$(pr_get g1)"
  read -r gm gmb gme <<< "$(pr_get gm)"
  read -r g4 g4b g4e <<< "$(pr_get g4)"
  read -r gu gub gue <<< "$(pr_get gu)"
  loss=$(grep -oE '[0-9.]+% packet loss' "$TMPD/ping.txt" | head -n1 | cut -d% -f1)
  rtt=$(grep -oE '= [0-9.]+/[0-9.]+/' "$TMPD/ping.txt" | head -n1 | cut -d/ -f2)
  loss="${loss:-100}"; rtt="${rtt:-?}"; rtt="${rtt%.*}"
  pmtu=$(cat "$TMPD/mtu.txt" 2>/dev/null); pmtu="${pmtu:-0}"
  asn=$(asn_info)

  # состояния всех вариантов
  local -A ST=() SL=()
  SL[g1]="TLS :8444, SNI $SNI_W"; SL[gm]="TLS :8444, SNI google, MSS 1200"
  SL[ya]="TLS :8444, SNI yandex.ru"; SL[vk]="TLS :8444, SNI vk.com"; SL[ms]="TLS :8444, SNI www.microsoft.com"
  SL[ns]="TLS :8444, без SNI"; SL[dm]="TLS :8444, SNI ${SNI_DOM}"; SL[gi]="TLS :8444, пауза 8 с, затем данные"
  SL[t12]="TLS 1.2 :8445, SNI $SNI_W"; SL[pa]="TLS :2087, SNI $SNI_W"; SL[pb]="TLS :9443, SNI $SNI_W"; SL[pc]="TLS :4443, SNI $SNI_W"
  SL[r8446]="Сырой TCP :8446 (без TLS)"; SL[h8447]="HTTP :8447, Host $SNI_W"; SL[h8447d]="HTTP :8447, Host ${SNI_DOM}"
  local item n
  for item in g1:8444 gm:8444 ya:8444 vk:8444 ms:8444 ns:8444 dm:8444 gi:8444 t12:8445 pa:2087 pb:9443 pc:4443 r8446:8446 h8447:8447 h8447d:8447; do
    n="${item%%:*}"
    { [ "$n" = dm ] || [ "$n" = h8447d ]; } && [ -z "$SNI_DOM" ] && continue
    ST[$n]=$(pr_state "$n" "${item##*:}")
  done

  local problems=() warns=() notes=() pass_l=() fail_l=()
  RAW_FROZEN=0
  for item in g1 gm ya vk ms ns dm gi t12 pa pb pc r8446 h8447 h8447d; do
    [ -n "${ST[$item]:-}" ] || continue
    [ "${ST[$item]}" = 1 ] && pass_l+=("${SL[$item]}")
    [ "${ST[$item]}" = 0 ] && fail_l+=("${SL[$item]}")
  done
  local cn=0 cp=0 c sz code
  for c in cf hz ovh gg; do
    read -r sz code < "$TMPD/ctl-$c.txt" 2>/dev/null || sz=0
    cn=$((cn + 1)); [ "${sz:-0}" -ge 1000000 ] && cp=$((cp + 1))
  done

  echo
  rule
  printf '  %sРезультаты теста BACKEND %s%s\n' "$B" "$BACKEND_IP" "$R"
  rule
  printf '  %sКанал%s\n' "$B" "$R"
  if [ "${loss%.*}" -ge 5 ]; then res_line fail "Канал (ping)" "RTT ${rtt} мс, потери ${loss}%"; problems+=("потери пакетов ${loss}% на пути до BACKEND")
  elif [ "${loss%.*}" -ge 1 ]; then res_line warn "Канал (ping)" "RTT ${rtt} мс, потери ${loss}%"; warns+=("есть потери пакетов (${loss}%)")
  else res_line ok "Канал (ping)" "RTT ${rtt} мс, потери ${loss}%"; fi
  if [ "$pmtu" -ge 1500 ]; then res_line ok "MTU пути" "1500 (без фрагментации)"
  elif [ "$pmtu" -gt 0 ]; then res_line warn "MTU пути" "$pmtu (меньше 1500)"
  else res_line warn "MTU пути" "не определён (ICMP с запретом фрагментации не проходит)"; fi
  [ -n "$asn" ] && res_line info "Сеть BACKEND" "$asn"

  printf '  %sСырой TCP и HTTP%s\n' "$B" "$R"
  raw_line "Сырой TCP (iperf3)" "$p1" "$p1b" "$p1r" "$p1e"
  raw_line "Сырой TCP (iperf3), MSS 1200" "$pm" "$pmb" "$pmr" "$pme"
  pr_line r8446 "${SL[r8446]}" 8446 4
  pr_line h8447 "${SL[h8447]}" 8447 4
  [ -n "$SNI_DOM" ] && pr_line h8447d "${SL[h8447d]}" 8447 4

  printf '  %sTLS 1.3, порт 8444 (SNI и MSS)%s\n' "$B" "$R"
  pr_line g1 "${SL[g1]}" 8444 6
  pr_line gm "${SL[gm]}" 8444 6
  pr_line ya "${SL[ya]}" 8444 4
  pr_line vk "${SL[vk]}" 8444 4
  pr_line ms "${SL[ms]}" 8444 4
  pr_line ns "${SL[ns]}" 8444 4
  [ -n "$SNI_DOM" ] && pr_line dm "${SL[dm]}" 8444 4
  pr_line gi "${SL[gi]}" 8444 4

  printf '  %sTLS: другие версии и порты%s\n' "$B" "$R"
  pr_line t12 "${SL[t12]}" 8445 4
  pr_line pa "${SL[pa]}" 2087 4
  pr_line pb "${SL[pb]}" 9443 4
  pr_line pc "${SL[pc]}" 4443 4

  if [ "${ST[g1]:-0}" = 1 ] || [ "${ST[gm]:-0}" = 1 ]; then
    printf '  %sСкорость (поток идёт)%s\n' "$B" "$R"
    tcp_line "TLS, 1 поток" "$g1" "$g1b" "-" "$g1e" 6 0 1
    tcp_line "TLS, 4 потока" "$g4" "$g4b" "-" "$g4e" 6 0
    tcp_line "TLS, отдача на BACKEND" "$gu" "$gub" "-" "$gue" 6 0
  fi

  printf '  %sUDP (порт 8448; важно для Hysteria2 / AmneziaWG)%s\n' "$B" "$R"
  local ue ub uer um umb ume udp_ok=0
  read -r ue ub uer <<< "$(pr_get uecho)"
  if [ "${ub:-0}" -ge 18 ]; then res_line ok "UDP, эхо" "${ub}/20 ответов"
  elif [ "${ub:-0}" -gt 0 ]; then res_line warn "UDP, эхо" "${ub}/20 ответов (потери)"
  else res_line fail "UDP, эхо" "ответов нет"; fi
  read -r um umb ume <<< "$(pr_get ublast)"
  if [ "${umb:-0}" -ge 200000 ] && [ -z "$ume" ]; then res_line ok "UDP, поток" "~${um} Мбит/с, потерь < 5%"; udp_ok=1
  elif [ "${umb:-0}" -gt 0 ]; then res_line warn "UDP, поток" "~${um} Мбит/с, $ume"
  else res_line fail "UDP, поток" "данные не приходят"; fi

  printf '  %sКонтроль: другие зарубежные сайты с RELAY%s\n' "$B" "$R"
  ctl_line cf "Cloudflare (speed.cloudflare.com)"
  ctl_line hz "Hetzner (speed.hetzner.de)"
  ctl_line ovh "OVH (proof.ovh.net)"
  ctl_line gg "Google (dl.google.com)"

  printf '  %sСистема%s\n' "$B" "$R"
  if [ "$cc_r" = bbr ] && [ "$cc_b" = bbr ]; then res_line ok "BBR / fq" "RELAY: $cc_r/$qd_r, BACKEND: $cc_b/$qd_b"
  else res_line warn "BBR / fq" "RELAY: ${cc_r:-?}/${qd_r:-?}, BACKEND: ${cc_b:-?}/${qd_b:-?}"; warns+=("BBR недоступен на одном из серверов (ядро или виртуализация хостера)"); fi
  rule

  # главный вывод: есть ли блокировка по объёму (16–20 КБ) и от чего она зависит
  local mtu_fix=1400
  [ "$pmtu" -gt 0 ] && [ "$pmtu" -lt 1400 ] && mtu_fix="$pmtu"
  if [ "${PS[8444]:-0}" != 1 ]; then
    res_line warn "Блокировка по 16 КБ" "не проверена: тестовый порт 8444 недоступен"
    problems+=("порт 8444 на BACKEND недоступен с RELAY: проверьте firewall хостера (в ufw порт уже открыт для RELAY)")
  elif [ "${ST[g1]}" = 1 ]; then
    res_line ok "Блокировка по 16 КБ" "нет: TLS-поток идёт полностью"
  elif [ "${ST[gm]}" = 1 ]; then
    res_line warn "Блокировка по 16 КБ" "нет, но проблема MTU/PMTUD"
    problems+=("с обычным MSS поток встаёт (~$((g1b / 1024)) КБ), с MSS 1200 идёт: это не блокировка по объёму, а потеря крупных пакетов (MTU/PMTUD)")
    notes+=("исправление: на ОБОИХ серверах уменьшить MTU, например: ip link set dev ${dev_r:-eth0} mtu ${mtu_fix} (RELAY) и ip link set dev ${dev_b:-eth0} mtu ${mtu_fix} (BACKEND); затем повторить тест (для постоянного эффекта — прописать MTU в netplan)")
  elif [ ${#pass_l[@]} -gt 0 ]; then
    res_line warn "Блокировка по 16 КБ" "частично: зависит от параметров"
    warns+=("потоки с SNI $SNI_W на порту 8444 встают (~$((g1b / 1024)) КБ), но проходят: $(joinl "${pass_l[@]}")")
    warns+=("режутся: $(joinl "${fail_l[@]}")")
    notes+=("для туннеля/VPN на этом участке используйте проходящие параметры (порт, SNI, версию TLS)")
  else
    res_line fail "Блокировка по 16 КБ" "ДА: потоки встают после ~$((g1b / 1024)) КБ при любых портах, SNI и версиях TLS"
    problems+=("TCP встаёт после ~$((g1b / 1024)) КБ при любых портах, SNI и версиях TLS — это блокировка/заморозка по объёму, не MTU")
    if [ "$cp" -gt 0 ]; then
      problems+=("контрольные зарубежные сайты с RELAY открываются ($cp из $cn): режется именно путь до BACKEND — смените IP/подсеть/хостера BACKEND")
    else
      problems+=("контрольные зарубежные сайты с RELAY тоже режутся: заморозка действует на любой TCP из этого места (RELAY/хостер → зарубеж), а не только на BACKEND")
    fi
    if [ $udp_ok -eq 1 ]; then notes+=("UDP проходит: используйте UDP-ветку (Hysteria2 / AmneziaWG), TCP-путь для этой пары серверов не годится")
    else notes+=("UDP тоже не проходит: этот путь между серверами для VPN не подходит"); fi
  fi

  if [ "${ST[g1]:-0}" = 1 ]; then
    if [ "$RAW_FROZEN" -eq 1 ] || [ "${ST[r8446]:-1}" = 0 ]; then
      notes+=("сырой TCP без TLS режется, а TLS с SNI $SNI_W проходит — для VPN это нормально: трафик VLESS/Reality выглядит как TLS")
    fi
    if [ -n "$SNI_DOM" ] && [ "${ST[dm]:-1}" = 0 ]; then
      warns+=("SNI вашего домена ($SNI_DOM) встаёт, а $SNI_W проходит: туннелю rathole (TLS с SNI домена) может понадобиться «белый» SNI")
    fi
    [ -z "$g4e" ] && [ "$g4" -ge $((g1 * 3)) ] && [ "$g1" -ge 1 ] && [ "$g1" -lt 200 ] && warns+=("один TLS-поток заметно медленнее четырёх: узким местом являются потери или окна TCP (используйте несколько соединений)")
    [ -z "$gue" ] && [ "$gu" -ge 1 ] && [ "$g1" -ge 1 ] && [ "$gu" -lt $((g1 * 3 / 10)) ] && warns+=("отдача на BACKEND в разы медленнее скачивания: проверьте асимметрию канала/лимиты хостера")
  fi
  local m
  if [ ${#problems[@]} -eq 0 ] && [ ${#warns[@]} -eq 0 ]; then
    echo "  ${GRN}${B}Итог: всё в порядке.${R} Блокировки по объёму нет, канал между серверами не ограничивает скорость."
  else
    if [ ${#problems[@]} -gt 0 ]; then echo "  ${RED}${B}Итог: найдены проблемы:${R}"; else echo "  ${YLW}${B}Итог: есть замечания:${R}"; fi
    for m in "${problems[@]}"; do echo "   ${RED}✖${R} $m"; done
    for m in "${warns[@]}"; do echo "   ${YLW}▲${R} $m"; done
  fi
  for m in "${notes[@]}"; do echo "   ${BLU}•${R} $m"; done
  echo "  ${DIM}Тест идёт напрямую RELAY→BACKEND, без туннеля rathole, на свободных портах. Сырые ответы: $LOG${R}"
  echo
}

iperf_stop() {
  [ "${IPERF_STARTED:-0}" = 1 ] || return 0
  rscript "$TMPD/iperf-stop.sh" "${RELAY_IP:-}" >>"$LOG" 2>&1 || true
  IPERF_STARTED=0
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
  command -v python3 >/dev/null 2>&1 || miss+=(python3)
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
  local all v6 x tgt="${DNS_TARGET:-$RELAY_IP}"
  while true; do
    all=$(dns_collect | grep -E '^[0-9]{1,3}(\.[0-9]{1,3}){3}$' | sort -u | tr '\n' ' ')
    all="${all% }"
    v6=$(dig +short +time=3 +tries=1 AAAA "$DOMAIN" @8.8.8.8 2>/dev/null | grep ':' | head -1)
    if [ "$all" = "$tgt" ] && [ -z "$v6" ]; then
      ok "DNS: $DOMAIN → $tgt"
      return 0
    fi
    echo
    rule
    printf '  %s▲ Проблема с DNS%s\n' "$YLW" "$R"
    echo "  Домен:        $DOMAIN"
    echo "  Сейчас:       A: ${all:-нет}   AAAA: ${v6:-нет}"
    echo "  Должно быть:  A = $tgt (IP сервера, DNS only, TTL 1 мин), AAAA — удалить"
    echo "  ${DIM}(IPv6 через туннель не пробрасывается, а Let's Encrypt проверяет по IPv6 первым)${R}"
    rule
    rd -r -p "  Нажмите Enter, когда исправили (n — пропустить проверку): " x
    if [[ "$x" =~ ^[nNнН] ]]; then
      warn "проверка DNS пропущена — сертификат может не выпуститься"
      return 1
    fi
  done
}

# ───────────────────────── SSH к BACKEND ─────────────────────────
read_key() {
  local line default_key="" f tries=0
  if [ -n "${KEY_PATH:-}" ] && [ -f "$KEY_PATH" ]; then
    default_key="$KEY_PATH"
  else
    for f in /root/.ssh/id_ed25519 /root/.ssh/id_rsa /root/.ssh/id_ecdsa; do
      [ -f "$f" ] && { default_key="$f"; break; }
    done
  fi
  while true; do
    tries=$((tries + 1))
    [ $tries -le 5 ] || die "ключ не получен за 5 попыток"
    echo "${B}?${R} Приватный ключ root для BACKEND: путь к файлу или вставьте ключ целиком ${DIM}(ввод скрыт)${R}"
    [ -n "$default_key" ] && echo "  ${DIM}Enter — использовать $default_key${R}"
    IFS= rd -r -s line
    echo
    line="${line//$'\r'/}"
    if [ -z "$line" ]; then
      if [ -n "$default_key" ]; then KEY_FILE="$default_key"; else fail "ключ не указан"; continue; fi
    elif [[ "$line" == -----BEGIN* ]]; then
      KEY_FILE="$TMPD/key"
      printf '%s\n' "$line" > "$KEY_FILE"
      while IFS= rd -r -s line; do
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
      [ "$KEY_FILE" != "$TMPD/key" ] && KEY_PATH="$KEY_FILE"
      return 0
    fi
    fail "ключ не читается (неверный формат или защищён паролем — такие не поддерживаются)"
    KEY_FILE=""
  done
}

# IP, SSH-порт и ключ для доступа к BACKEND (используется в тесте и удалении)
ask_backend() {
  while true; do
    ask BACKEND_IP "IP BACKEND" ""
    valid_ip "$BACKEND_IP" && break
    fail "неверный IP"
    BACKEND_IP=""
  done
  LOCAL_BACKEND=0
  if [ "$BACKEND_IP" = "${RELAY_IP:-}" ]; then
    LOCAL_BACKEND=1
    ok "это текущий сервер: действия выполняются локально (без SSH)"
    return 0
  fi
  while true; do
    ask BACKEND_PORT "SSH-порт BACKEND" "${BACKEND_PORT:-1119}"
    valid_port "$BACKEND_PORT" && break
    fail "неверный порт"
  done
  [ -n "${KEY_FILE:-}" ] || read_key
}

ssh_opts() {
  SSH_OPTS=(-i "$KEY_FILE" -p "$BACKEND_PORT" -o IdentitiesOnly=yes
    -o StrictHostKeyChecking=accept-new -o ServerAliveInterval=15 -o ServerAliveCountMax=4
    -o ConnectTimeout=15 -o ControlMaster=auto -o "ControlPath=$TMPD/cm-%C" -o ControlPersist=1800)
}

LOCAL_BACKEND=0
bk() {
  if [ "${LOCAL_BACKEND:-0}" = 1 ]; then bash -c "$*"; else ssh "${SSH_OPTS[@]}" "root@$BACKEND_IP" "$@"; fi
}
rscript() {
  local f="$1"; shift
  if [ "${LOCAL_BACKEND:-0}" = 1 ]; then bash -s -- "$@" < "$f"; else ssh "${SSH_OPTS[@]}" "root@$BACKEND_IP" bash -s -- "$@" < "$f"; fi
}

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
mkdir -p /var/www/certbot
cat > /etc/nginx/sites-available/apex.conf <<EOT
server {
    listen 80;
    listen [::]:80;
    server_name $DOMAIN;

    server_tokens off;
    add_header X-Content-Type-Options "nosniff" always;
    add_header X-Frame-Options "SAMEORIGIN" always;
    add_header Referrer-Policy "strict-origin-when-cross-origin" always;

    location ^~ /.well-known/acme-challenge/ {
        root /var/www/certbot;
    }

    # BEGIN sub-paths
    # END sub-paths

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
mkdir -p /var/www/certbot
certbot certonly --webroot -w /var/www/certbot -d "$DOMAIN" --non-interactive --agree-tos -m "$EMAIL" --deploy-hook "systemctl reload nginx"
EOF

  cat > "$D/nginx-final.sh" <<'EOF'
set -e
DOMAIN="$1"
cat > /etc/nginx/sites-available/apex.conf <<EOT
server {
    listen 80;
    listen [::]:80;
    server_name $DOMAIN;

    location ^~ /.well-known/acme-challenge/ {
        root /var/www/certbot;
    }

    location / {
        return 301 https://\$host\$request_uri;
    }
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

    # BEGIN sub-paths
    # END sub-paths

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
# прежние глобальные хуки (stop/start nginx) мешали продлению других сертификатов — убираем
rm -f /etc/letsencrypt/renewal-hooks/pre/stop-nginx.sh /etc/letsencrypt/renewal-hooks/post/start-nginx.sh
/usr/local/bin/sync-sub-path || true
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
cat > /usr/local/bin/sync-sub-path <<'EOT2'
#!/usr/bin/env python3
# Берёт пути подписки из базы 3x-ui и прописывает их в nginx (apex.conf, блок sub-paths).
# Запускается таймером раз в минуту: если путь в панели изменили, nginx подхватит сам.
import re, sqlite3, subprocess, sys

DB = "/etc/x-ui/x-ui.db"
CONF = "/etc/nginx/sites-available/apex.conf"
BEGIN, END = "    # BEGIN sub-paths\n", "    # END sub-paths\n"

try:
    txt = open(CONF).read()
except OSError:
    sys.exit(0)
if BEGIN not in txt or END not in txt:
    sys.exit(0)
try:
    c = sqlite3.connect(DB, timeout=5)

    def get(k, d):
        r = c.execute("select value from settings where key=?", (k,)).fetchone()
        return (r[0] if r and r[0] else d)

    port = get("subPort", "2096")
    paths = []
    for k, d in (("subPath", "/sub/"), ("subJsonPath", "/json/"), ("subClashPath", "/clash/")):
        p = "/" + get(k, d).strip("/") + "/"
        if p != "//" and p not in paths:
            paths.append(p)
except Exception as e:
    sys.exit("sync-sub-path: не удалось прочитать настройки панели: %s" % e)

loc = (
    "    location ^~ {p} {{\n"
    "        proxy_pass http://127.0.0.1:{port};\n"
    "        proxy_set_header Host $host;\n"
    "        proxy_set_header X-Real-IP $remote_addr;\n"
    "        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;\n"
    "        proxy_set_header X-Forwarded-Proto $scheme;\n"
    "    }}\n\n"
)
block = BEGIN + "".join(loc.format(p=p, port=port) for p in paths) + END
new = re.sub(re.escape(BEGIN) + ".*?" + re.escape(END), lambda m: block, txt, flags=re.S)
if new == txt:
    sys.exit(0)
open(CONF, "w").write(new)
if subprocess.call(["nginx", "-t"], stderr=subprocess.DEVNULL) != 0:
    open(CONF, "w").write(txt)
    sys.exit("sync-sub-path: nginx -t не прошёл, изменения отменены")
subprocess.call(["systemctl", "reload", "nginx"])
print("sync-sub-path: nginx обновлён, пути подписки: " + " ".join(paths))
EOT2
chmod +x /usr/local/bin/sync-sub-path
cat > /etc/systemd/system/sync-sub-path.service <<'EOT3'
[Unit]
Description=Sync 3x-ui subscription paths into nginx

[Service]
Type=oneshot
LogLevelMax=notice
ExecStart=/usr/local/bin/sync-sub-path
EOT3
cat > /etc/systemd/system/sync-sub-path.timer <<'EOT3'
[Unit]
Description=Sync 3x-ui subscription paths into nginx every 15 seconds

[Timer]
OnBootSec=30
OnUnitActiveSec=15
AccuracySec=1s

[Install]
WantedBy=timers.target
EOT3
systemctl daemon-reload
systemctl enable --now sync-sub-path.timer >/dev/null 2>&1
EOF

  # сетевые твики на BACKEND (та же функция, что и на RELAY)
  { declare -f tune_network; echo "tune_network"; } > "$D/tune.sh"

  # подписка: включить, слушать только локально, прописать URI обратного прокси; печатает пути из панели
  cat > "$D/sub-setup.sh" <<'EOF'
set -e
DOMAIN="$1"; SCHEME="$2"
systemctl stop x-ui
python3 - "$DOMAIN" "$SCHEME" <<'PY'
import sqlite3, sys
domain, scheme = sys.argv[1], sys.argv[2]
c = sqlite3.connect("/etc/x-ui/x-ui.db")

def get(k, d=""):
    r = c.execute("select value from settings where key=?", (k,)).fetchone()
    return r[0] if r and r[0] else d

def put(k, v):
    if c.execute("select 1 from settings where key=?", (k,)).fetchone():
        c.execute("update settings set value=? where key=?", (v, k))
    else:
        c.execute("insert into settings(key,value) values(?,?)", (k, v))

norm = lambda p: "/" + p.strip("/") + "/"
sp, jp, cp = (norm(get(k, d)) for k, d in (("subPath", "/sub/"), ("subJsonPath", "/json/"), ("subClashPath", "/clash/")))
put("subEnable", "true")
put("subListen", "127.0.0.1")
put("subPort", get("subPort", "2096"))
base = scheme + "://" + domain
put("subURI", base + sp)
put("subJsonURI", base + jp)
put("subClashURI", base + cp)
c.commit()
print(sp)
PY
systemctl start x-ui
sleep 2
systemctl is-active --quiet x-ui
EOF

  cat > "$D/iperf-install.sh" <<'EOF'
set -e
export DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=a
apt-get -o DPkg::Lock::Timeout=300 update -y
apt-get -o DPkg::Lock::Timeout=300 install -y iperf3
EOF

  cat > "$D/iperf-server.sh" <<'EOF'
set -e
RELAY="$1"
rm -f /run/relay-iperf.fw
if ufw status 2>/dev/null | grep -q '^Status: active'; then
  ufw allow from "$RELAY" to any port 5201 proto tcp >/dev/null
  touch /run/relay-iperf.fw
fi
if [ -f /run/relay-iperf3.pid ]; then kill "$(cat /run/relay-iperf3.pid)" 2>/dev/null || true; fi
iperf3 -s -D -4 -p 5201 -I /run/relay-iperf3.pid
sleep 1
ss -tlnH | grep -q ':5201 '
EOF

  cat > "$D/iperf-stop.sh" <<'EOF'
RELAY="$1"
if [ -f /run/relay-iperf3.pid ]; then kill "$(cat /run/relay-iperf3.pid)" 2>/dev/null || true; rm -f /run/relay-iperf3.pid; fi
if [ -f /run/relay-iperf.fw ]; then ufw delete allow from "$RELAY" to any port 5201 proto tcp >/dev/null 2>&1 || true; rm -f /run/relay-iperf.fw; fi
if [ -f /run/relay-tls.pid ]; then kill "$(cat /run/relay-tls.pid)" 2>/dev/null || true; rm -f /run/relay-tls.pid /run/relay-tls-srv.py /run/relay-tls.key /run/relay-tls.crt; fi
if [ -f /run/relay-tls.fw ]; then
  while read -r spec; do
    [ -n "$spec" ] && ufw delete allow from "$RELAY" to any port "${spec%/*}" proto "${spec#*/}" >/dev/null 2>&1 || true
  done < /run/relay-tls.fw
  rm -f /run/relay-tls.fw
fi
rm -f /run/relay-test.ports
true
EOF

  cat > "$D/tlstest-start.sh" <<'EOF'
set -e
RELAY="$1"
rm -f /run/relay-tls.fw /run/relay-test.ports
if [ -f /run/relay-tls.pid ]; then kill "$(cat /run/relay-tls.pid)" 2>/dev/null || true; sleep 0.5; fi
openssl req -x509 -newkey rsa:2048 -nodes -keyout /run/relay-tls.key -out /run/relay-tls.crt -days 1 -subj "/CN=localhost" >/dev/null 2>&1
cat > /run/relay-tls-srv.py <<'PYEOF'
import socket, ssl, struct, threading, time

CRT, KEY = "/run/relay-tls.crt", "/run/relay-tls.key"
ctx13 = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
ctx13.load_cert_chain(CRT, KEY)
ctx12 = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
ctx12.load_cert_chain(CRT, KEY)
ctx12.maximum_version = ssl.TLSVersion.TLSv1_2
chunk = b"x" * 65536
bound = []

def stream(c, mode):
    end = time.time() + 12
    if mode == b"D":
        while time.time() < end:
            c.sendall(chunk)
    elif mode == b"U":
        while time.time() < end:
            if not c.recv(65536):
                break

def handle_stream(c, ctx):
    try:
        if ctx is not None:
            c = ctx.wrap_socket(c, server_side=True)
        c.settimeout(15)
        stream(c, c.recv(1))
    except Exception:
        pass
    finally:
        try:
            c.close()
        except Exception:
            pass

def handle_http(c):
    try:
        c.settimeout(15)
        data = b""
        while b"\r\n\r\n" not in data and len(data) < 8192:
            d = c.recv(4096)
            if not d:
                break
            data += d
        c.sendall(b"HTTP/1.1 200 OK\r\nContent-Type: application/octet-stream\r\nContent-Length: 1073741824\r\nConnection: close\r\n\r\n")
        end = time.time() + 12
        while time.time() < end:
            c.sendall(chunk)
    except Exception:
        pass
    finally:
        try:
            c.close()
        except Exception:
            pass

def listen(port, handler, kind):
    try:
        srv = socket.socket()
        srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        srv.bind(("0.0.0.0", port))
        srv.listen(64)
    except OSError:
        return
    bound.append("tcp:%d:%s" % (port, kind))
    def loop():
        while True:
            c, _ = srv.accept()
            threading.Thread(target=handler, args=(c,), daemon=True).start()
    threading.Thread(target=loop, daemon=True).start()

def blast(u, addr):
    seq = 0
    end = time.time() + 4
    body = b"y" * 1196
    while time.time() < end:
        for _ in range(50):
            u.sendto(struct.pack(">I", seq) + body, addr)
            seq += 1
        time.sleep(0.01)
    for _ in range(5):
        u.sendto(b"Z" + struct.pack(">I", seq), addr)

def udp_loop():
    try:
        u = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        u.bind(("0.0.0.0", 8448))
    except OSError:
        return
    bound.append("udp:8448:udp")
    while True:
        data, addr = u.recvfrom(2048)
        if data[:1] == b"E":
            u.sendto(data, addr)
        elif data[:1] == b"D":
            threading.Thread(target=blast, args=(u, addr), daemon=True).start()

for prt in (8444, 2087, 9443, 4443):
    listen(prt, lambda c: handle_stream(c, ctx13), "tls13")
listen(8445, lambda c: handle_stream(c, ctx12), "tls12")
listen(8446, lambda c: handle_stream(c, None), "raw")
listen(8447, handle_http, "http")
threading.Thread(target=udp_loop, daemon=True).start()
time.sleep(0.5)
open("/run/relay-test.ports", "w").write("\n".join(bound) + "\n")
while True:
    time.sleep(3600)
PYEOF
nohup python3 /run/relay-tls-srv.py >/dev/null 2>&1 &
echo $! > /run/relay-tls.pid
sleep 1.5
[ -s /run/relay-test.ports ]
if ufw status 2>/dev/null | grep -q '^Status: active'; then
  while IFS=: read -r proto port kind; do
    [ -n "$port" ] || continue
    ufw allow from "$RELAY" to any port "$port" proto "$proto" >/dev/null
    echo "$port/$proto" >> /run/relay-tls.fw
  done < /run/relay-test.ports
fi
EOF

  # клиент TLS-теста (запускается на RELAY): "Мбит/с байт ошибка"
  cat > "$D/tlstest-client.py" <<'EOF'
import socket, ssl, struct, sys, threading, time

kind = sys.argv[1]

def tcp_run():
    host, port, sni, mode, n, secs = sys.argv[2], int(sys.argv[3]), sys.argv[4], sys.argv[5], int(sys.argv[6]), float(sys.argv[7])
    mss = int(sys.argv[8]) if len(sys.argv) > 8 else 0
    idle = float(sys.argv[9]) if len(sys.argv) > 9 else 0
    ctx = ssl.create_default_context()
    ctx.check_hostname = False
    ctx.verify_mode = ssl.CERT_NONE
    total = [0] * n
    errs = [""] * n
    host_hdr = host if sni == "-" else sni
    req = ("GET /big.bin HTTP/1.1\r\nHost: %s\r\nUser-Agent: Mozilla/5.0\r\nAccept: */*\r\nConnection: close\r\n\r\n" % host_hdr).encode()

    def worker(i):
        phase = "CONNECT"
        try:
            s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
            if mss:
                s.setsockopt(socket.IPPROTO_TCP, socket.TCP_MAXSEG, mss)
            s.settimeout(8)
            s.connect((host, port))
            conn = s
            if kind == "tls":
                phase = "HANDSHAKE"
                conn = ctx.wrap_socket(s, server_hostname=None if sni == "-" else sni)
            conn.settimeout(5)
            phase = "DATA"
            if idle:
                time.sleep(idle)
            if kind == "http":
                conn.sendall(req)
                m = "D"
            else:
                conn.sendall(mode.encode())
                m = mode
            end = time.time() + secs
            buf = b"x" * 65536
            while time.time() < end:
                if m == "D":
                    d = conn.recv(262144)
                    if not d:
                        break
                    total[i] += len(d)
                else:
                    conn.sendall(buf)
                    total[i] += len(buf)
        except (socket.timeout, TimeoutError):
            errs[i] = "STALL" if phase == "DATA" else phase + ": timeout"
        except Exception as e:
            msg = str(e)
            if phase == "DATA" and "timed out" in msg:
                errs[i] = "STALL"
            else:
                errs[i] = phase + ": " + type(e).__name__ + " " + msg[:50].replace("\n", " ")

    th = [threading.Thread(target=worker, args=(i,)) for i in range(n)]
    t0 = time.time()
    for x in th:
        x.start()
    for x in th:
        x.join(secs + idle + 12)
    el = max(time.time() - t0 - idle, 0.001)
    b = sum(total)
    print(int(b * 8 / el / 1e6), b, next((e for e in errs if e), ""))

def udp_echo():
    host, port = sys.argv[2], int(sys.argv[3])
    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    s.settimeout(0.3)
    got = 0
    for i in range(20):
        s.sendto(b"E" + struct.pack(">I", i) + b"p" * 60, (host, port))
        try:
            d, _ = s.recvfrom(2048)
            if d[:1] == b"E":
                got += 1
        except socket.timeout:
            pass
        time.sleep(0.05)
    print(0, got, "")

def udp_blast():
    host, port, secs = sys.argv[2], int(sys.argv[3]), float(sys.argv[4])
    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    s.settimeout(1.0)
    for _ in range(3):
        s.sendto(b"D", (host, port))
    seqs = set()
    total_hint = 0
    t0 = time.time()
    last = t0
    while time.time() < t0 + secs + 2:
        try:
            d, _ = s.recvfrom(2048)
        except socket.timeout:
            if seqs and time.time() - last > 1.5:
                break
            if not seqs and time.time() - t0 > 3:
                break
            continue
        last = time.time()
        if d[:1] == b"Z":
            total_hint = struct.unpack(">I", d[1:5])[0]
            break
        seqs.add(struct.unpack(">I", d[:4])[0])
    recv = len(seqs)
    sent = max(total_hint, (max(seqs) + 1) if seqs else 0)
    dur = max(time.time() - t0, 0.001)
    loss = int(100 * (1 - recv / sent)) if sent else 100
    print(int(recv * 1200 * 8 / dur / 1e6), recv * 1200, "" if recv and loss < 5 else "loss %d%%" % loss)

{"udp-echo": udp_echo, "udp-blast": udp_blast}.get(kind, tcp_run)()
EOF

  cat > "$D/uninstall-backend.sh" <<'EOF'
RELAY="$1"; DOMAIN="$2"; RM_XUI="$3"; RM_WEB="$4"; DIRECT="${5:-0}"
systemctl disable --now rathole >/dev/null 2>&1 || true
rm -f /etc/systemd/system/rathole.service /usr/local/bin/rathole /usr/local/bin/switch-relay
rm -rf /etc/rathole
systemctl disable --now sync-sub-path.timer >/dev/null 2>&1 || true
rm -f /etc/systemd/system/sync-sub-path.service /etc/systemd/system/sync-sub-path.timer /usr/local/bin/sync-sub-path
rm -f /etc/sysctl.d/99-relay-network-tuning.conf /etc/modules-load.d/relay-bbr.conf
systemctl daemon-reload
[ -n "$RELAY" ] && ufw delete allow from "$RELAY" to any port 8443 proto udp >/dev/null 2>&1 || true
if [ "$DIRECT" = 1 ]; then
  for r in 80/tcp 443/tcp 8443/tcp 8443/udp; do ufw delete allow "$r" >/dev/null 2>&1 || true; done
fi
if [ "$RM_XUI" = 1 ]; then
  systemctl disable --now x-ui >/dev/null 2>&1 || true
  rm -rf /usr/local/x-ui /etc/x-ui /usr/bin/x-ui /etc/systemd/system/x-ui.service
  systemctl daemon-reload
fi
if [ "$RM_WEB" = 1 ]; then
  rm -f /etc/nginx/sites-enabled/apex.conf /etc/nginx/sites-available/apex.conf
  [ -n "$DOMAIN" ] && certbot delete --cert-name "$DOMAIN" --non-interactive >/dev/null 2>&1 || true
  rm -f /etc/letsencrypt/renewal-hooks/pre/stop-nginx.sh /etc/letsencrypt/renewal-hooks/post/start-nginx.sh
  nginx -t >/dev/null 2>&1 && systemctl reload nginx >/dev/null 2>&1 || true
fi
true
EOF

  # firewall для режима «Backend без relay»: порты открыты для всех
  cat > "$D/ufw-backend-direct.sh" <<'EOF'
set -e
ports=$( {
  ss -tlnp 2>/dev/null | awk '/"sshd"/ { n = split($4, a, ":"); print a[n] }'
  sshd -T 2>/dev/null | awk '/^port / { print $2 }'
  systemctl show ssh.socket -p Listen 2>/dev/null | sed -n 's/^Listen=.*:\([0-9][0-9]*\) (Stream)$/\1/p'
  [ -n "${SSH_CONNECTION:-}" ] && echo "$SSH_CONNECTION" | awk '{ print $4 }'
} | grep -E '^[0-9]+$' | sort -un || true )
[ -n "$ports" ] || { echo "sshd port not found" >&2; exit 1; }
for p in $ports; do ufw allow "$p/tcp"; done
ufw allow 80/tcp
ufw allow 443/tcp
ufw allow 8443/tcp
ufw allow 8443/udp
ufw --force enable
ufw status
EOF

  # служебная команда без switch-relay (режим без relay): только sync-sub-path и таймер
  sed '/^cat > \/usr\/local\/bin\/switch-relay/,/^chmod +x \/usr\/local\/bin\/switch-relay/d' "$D/helper-backend.sh" > "$D/helper-sub.sh"

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
RELAY_IP=${RELAY_IP:-}
BACKEND_IP=${BACKEND_IP:-}
BACKEND_PORT=${BACKEND_PORT:-}
DOMAIN=${DOMAIN:-}
EMAIL=${EMAIL:-}
SECRET=${SECRET:-}
KEY_PATH=${KEY_PATH:-}
EOF
  chmod 600 "$CONF_FILE"
}

cleanup() {
  [ -n "${TMPD:-}" ] && [ -d "$TMPD" ] && [ "${IPERF_STARTED:-0}" = 1 ] && { iperf_stop; }
  [ -n "${TMPD:-}" ] && [ -d "$TMPD" ] && {
    [ -n "${SSH_OPTS+x}" ] && ssh "${SSH_OPTS[@]}" -O exit "root@${BACKEND_IP:-x}" >/dev/null 2>&1 || true
    rm -rf "$TMPD"
  }
  printf '%s' "$R"
}

# ───────────────────────── основной сценарий ─────────────────────────
preflight() {
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

}

check_reinstall() {
  if [ -f "$MARKER_FILE" ]; then
    warn "установка уже выполнялась (метка: $(marker_get INSTALLED_AT), статус: $(marker_get STATUS))"
    confirm "Удалить всё и установить заново?" || { echo "  Отменено."; exit 0; }
    do_uninstall || exit 0
  fi
}

# установка 3x-ui и вывод данных панели (глобальные xu xp xw xt)
xui_stage() {
  step_run "Установка 3x-ui (SQLite, порт $PANEL_PORT, панель на 127.0.0.1)" rscript "$TMPD/xui.sh" "$PANEL_PORT" || die "3x-ui не установился"
  local res
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

}

backend_os_check() {
  local bos
  bos=$(bk '. /etc/os-release; echo "$ID $VERSION_ID"' 2>>"$LOG")
  case "$bos" in
    ubuntu\ *) if version_ge "${bos#ubuntu }" 22.04; then ok "ОС: Ubuntu ${bos#ubuntu }"; else die "нужна Ubuntu 22.04 или новее (найдена ${bos#ubuntu })"; fi ;;
    debian\ *) warn "ОС: $bos (скрипт рассчитан на Ubuntu 22.04+)" ;;
    *) warn "ОС не определена: ${bos:-?}" ;;
  esac
}

# ───────────────────────── режим 1: Backend без relay ─────────────────────────
run_install_backend() {
  INSTALL_KIND="backend"
  STEP=0; TOTAL=9
  check_reinstall
  STEP=0; TOTAL=9
  SECRET="${SECRET:-}"

  echo
  echo "${B}Параметры${R}"
  thin
  while true; do
    ask BACKEND_IP "IP сервера (этот сервер или удалённый, настраивается по SSH)" ""
    valid_ip "$BACKEND_IP" && break
    fail "неверный IP"
    BACKEND_IP=""
  done
  LOCAL_BACKEND=0
  if [ "$BACKEND_IP" = "$RELAY_IP" ]; then
    LOCAL_BACKEND=1
    ok "это текущий сервер: установка выполняется локально (без SSH)"
  else
    while true; do
      ask BACKEND_PORT "SSH-порт сервера" "${BACKEND_PORT:-1119}"
      valid_port "$BACKEND_PORT" && break
      fail "неверный порт"
    done
    [ -n "${KEY_FILE:-}" ] || read_key
  fi
  while true; do
    ask DOMAIN "Домен панели (A-запись → IP сервера)" "${DOMAIN:-}"
    valid_dom "$DOMAIN" && break
    fail "неверный домен"
    DOMAIN=""
  done
  EMAIL="admin@$DOMAIN"   # e-mail для Let's Encrypt: не спрашиваем
  DNS_TARGET="$BACKEND_IP"
  echo
  dns_check
  DNS_OK=$?

  echo
  rule
  printf '  %sПлан установки (Backend без relay)%s\n' "$B" "$R"
  rule
  if [ $LOCAL_BACKEND -eq 1 ]; then kv "Server" "$BACKEND_IP (этот сервер, локально)"; else kv "Server" "$BACKEND_IP (SSH :$BACKEND_PORT)"; fi
  kv "Domain" "$DOMAIN → https://$DOMAIN/<WebBasePath>"
  kv "E-mail" "$EMAIL"
  kv "Ports" "открываются 80, 443, 8443/tcp, 8443/udp; SSH сохраняется (ufw)"
  kv "Panel" "3x-ui на 127.0.0.1:$PANEL_PORT (SQLite), nginx + Let's Encrypt"
  kv "Network" "BBR, буферы TCP/UDP, MTU probing"
  rule
  echo
  confirm "Всё верно, начать установку?" || { echo "  Отменено."; exit 0; }
  write_marker in-progress
  make_remote_scripts

  # [1]
  section "Подключение к серверу"
  if [ $LOCAL_BACKEND -eq 1 ]; then ok "локальный режим (SSH не нужен)"; else ssh_connect; fi
  backend_os_check

  # [2]
  section "Сетевая оптимизация"
  step_run "BBR, буферы TCP/UDP, MTU probing, keepalive" rscript "$TMPD/tune.sh" || warn "твики применены не полностью"
  local cc
  cc=$(bk 'sysctl -n net.ipv4.tcp_congestion_control' 2>>"$LOG")
  if [ "$cc" = bbr ]; then ok "congestion control = bbr"; else warn "congestion control = ${cc:-?} (BBR недоступен: ядро или виртуализация)"; fi

  # [3]
  section "Пакеты и обновление системы"
  step_run "apt update/upgrade, nginx, certbot, ufw" rscript "$TMPD/pkgs.sh" || die "не удалось подготовить сервер"

  # [4] firewall до выпуска сертификата
  section "Firewall"
  step_run "ufw: SSH сохранён, открыты 80, 443, 8443/tcp, 8443/udp" rscript "$TMPD/ufw-backend-direct.sh" || die "не удалось настроить firewall"

  # [5]
  section "3x-ui"
  xui_stage

  # [6]
  section "nginx (временный конфиг)"
  step_run "nginx: порт 80 → панель" rscript "$TMPD/nginx-temp.sh" "$DOMAIN" || die "nginx не настроился"
  local code
  code=$(bk "curl -s -o /dev/null --max-time 15 -w '%{http_code}' -H 'Host: $DOMAIN' http://127.0.0.1:80/" 2>>"$LOG")
  if [ -n "$code" ] && [ "$code" != "000" ]; then ok "nginx отвечает на порту 80 (HTTP $code)"; else warn "nginx не отвечает на порту 80"; fi

  # [7]
  section "Сертификат Let's Encrypt"
  CERT_OK=0
  if [ "$DNS_OK" -ne 0 ]; then warn "DNS не подтверждён — попытка выпуска может не удаться"; fi
  while true; do
    if step_run "certbot --webroot для $DOMAIN" rscript "$TMPD/cert.sh" "$DOMAIN" "$EMAIL"; then CERT_OK=1; break; fi
    warn "не удалось выпустить сертификат (DNS ещё не разошёлся? порт 80 недоступен?)"
    confirm "Повторить?" || break
  done

  # [8]
  section "nginx (финальный конфиг), подписка, автопродление"
  step_run "Служебная команда sync-sub-path (автосинхронизация подписки)" rscript "$TMPD/helper-sub.sh" || warn "sync-sub-path не установлен"
  local scheme=http
  [ $CERT_OK -eq 1 ] && scheme=https
  SUB_PATHS=$(rscript "$TMPD/sub-setup.sh" "$DOMAIN" "$scheme" 2>>"$LOG" | tail -n1)
  bk "/usr/local/bin/sync-sub-path" >>"$LOG" 2>&1 || true
  if [ -n "$SUB_PATHS" ]; then ok "подписка: путь из панели $SUB_PATHS внесён в nginx (смена пути в панели подхватывается за ~15 с)"; else warn "не удалось настроить подписку (см. лог)"; fi
  if [ $CERT_OK -eq 1 ]; then
    step_run "nginx: сертификат, пути подписки из панели, автопродление" rscript "$TMPD/nginx-final.sh" "$DOMAIN" || die "не удалось включить финальный конфиг nginx"
  else
    warn "без сертификата оставлен временный конфиг: панель доступна по http://$DOMAIN/$xw"
  fi

  # [9]
  section "Проверка и итог"
  save_conf
  write_marker "done"
  ok "настройки сохранены: $CONF_FILE, метка установки: $MARKER_FILE"
  local final_url final_code
  if [ $CERT_OK -eq 1 ]; then
    final_url="https://$DOMAIN/$xw"
    final_code=$(curl -s -o /dev/null --max-time 15 -w '%{http_code}' "$final_url" 2>/dev/null)
    if [ "$final_code" = "200" ]; then ok "HTTPS: $final_url → HTTP 200 (сертификат валиден)"; else warn "HTTPS-проверка вернула HTTP ${final_code:-000} (DNS мог ещё не разойтись)"; fi
  else
    final_url="http://$DOMAIN/$xw"
  fi
  {
    echo "Backend Setup (без relay) v$VERSION — $(date '+%F %T')"
    echo "Server:       $BACKEND_IP"
    echo "Domain:       $DOMAIN"
    echo "Panel URL:    $final_url"
    echo "Username:     $xu"
    echo "Password:     $xp"
    echo "API Token:    ${xt:-—}"
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
  echo
  echo "  ${B}Дальше — в панели:${R}"
  echo "   • VLESS Reality: Listen IP пусто (все интерфейсы), порт 8443, пользовательский адрес $DOMAIN"
  echo "   • Hysteria2: Listen пусто, порт 8443/udp, SNI $DOMAIN, сертификат /etc/letsencrypt/live/$DOMAIN/"
  echo "   • Подписка уже настроена: путь ${SUB_PATHS:-?}, ссылки вида $scheme://$DOMAIN${SUB_PATHS:-/}<subId>."
  echo "     Если смените путь в панели — nginx подхватит сам за ~15 секунд (вручную: sync-sub-path)"
  echo "   • Панель безопаснее открывать через SSH-туннель: ssh -L 9999:127.0.0.1:$PANEL_PORT root@$BACKEND_IP → http://127.0.0.1:9999/$xw"
  echo
}

run_install() {
  INSTALL_KIND="relay"
  STEP=0; TOTAL=14
  check_reinstall
  STEP=0; TOTAL=14

  # ── вопросы
  echo
  echo "${B}Параметры${R}"
  thin
  while true; do
    ask BACKEND_IP "IP BACKEND" ""
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
  [ -n "${KEY_FILE:-}" ] || read_key
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
  write_marker in-progress

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

  # [3] сетевые твики (до запуска туннеля)
  section "Сетевая оптимизация (RELAY и BACKEND)"
  step_run "RELAY: BBR, буферы TCP/UDP, MTU probing, keepalive" tune_network || warn "твики на RELAY применены не полностью"
  step_run "BACKEND: BBR, буферы TCP/UDP, MTU probing, keepalive" rscript "$TMPD/tune.sh" || warn "твики на BACKEND применены не полностью"
  local cc_r cc_b
  cc_r=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null)
  cc_b=$(bk 'sysctl -n net.ipv4.tcp_congestion_control' 2>>"$LOG")
  if [ "$cc_r" = bbr ]; then ok "RELAY: congestion control = bbr"; else warn "RELAY: congestion control = ${cc_r:-?} (BBR недоступен: ядро или виртуализация)"; fi
  if [ "$cc_b" = bbr ]; then ok "BACKEND: congestion control = bbr"; else warn "BACKEND: congestion control = ${cc_b:-?} (BBR недоступен: ядро или виртуализация)"; fi

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
  xui_stage

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
    if step_run "certbot --webroot для $DOMAIN" rscript "$TMPD/cert.sh" "$DOMAIN" "$EMAIL"; then CERT_OK=1; break; fi
    warn "не удалось выпустить сертификат (DNS ещё не разошёлся? порт 80 недоступен?)"
    confirm "Повторить?" || break
  done

  # [12] nginx финальный, служебные команды и подписка
  section "BACKEND: nginx (финальный конфиг), подписка, автопродление"
  step_run "Служебные команды: switch-relay, sync-sub-path (автосинхронизация подписки)" rscript "$TMPD/helper-backend.sh" || warn "служебные команды не установлены"
  local scheme=http
  [ $CERT_OK -eq 1 ] && scheme=https
  SUB_PATHS=$(rscript "$TMPD/sub-setup.sh" "$DOMAIN" "$scheme" 2>>"$LOG" | tail -n1)
  bk "/usr/local/bin/sync-sub-path" >>"$LOG" 2>&1 || true
  if [ -n "$SUB_PATHS" ]; then ok "подписка: путь из панели $SUB_PATHS внесён в nginx (смена пути в панели подхватывается за ~15 с)"; else warn "не удалось настроить подписку (см. лог)"; fi
  if [ $CERT_OK -eq 1 ]; then
    step_run "nginx: сертификат, пути подписки из панели, автопродление" rscript "$TMPD/nginx-final.sh" "$DOMAIN" || die "не удалось включить финальный конфиг nginx"
  else
    warn "без сертификата оставлен временный конфиг: панель доступна по http://$DOMAIN/$xw"
  fi

  # [12] firewall BACKEND
  section "BACKEND: firewall"
  step_run "ufw: SSH сохранён, TCP 443/80/8443 закрыты, 8443/udp только от RELAY" rscript "$TMPD/ufw-backend.sh" "$RELAY_IP" || die "не удалось настроить firewall BACKEND"

  # [13] итог
  section "Проверка связки и служебные команды"
  ok "switch-backend установлен на RELAY"
  save_conf
  write_marker "done"
  ok "настройки сохранены: $CONF_FILE, метка установки: $MARKER_FILE"
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
  echo "  ${DIM}Служебные команды:     switch-relay (BACKEND), switch-backend (RELAY), sync-sub-path (BACKEND)${R}"
  echo
  echo "  ${B}Дальше — в панели:${R}"
  echo "   • VLESS Reality: Listen IP 127.0.0.1, порт 8443, пользовательский адрес $DOMAIN"
  echo "   • Hysteria2: Listen пусто, порт 8443/udp, SNI $DOMAIN, сертификат /etc/letsencrypt/live/$DOMAIN/"
  echo "   • Подписка уже настроена: путь ${SUB_PATHS:-?}, ссылки вида $scheme://$DOMAIN${SUB_PATHS:-/}<subId>."
  echo "     Если смените путь в панели — nginx подхватит сам за ~15 секунд (вручную: sync-sub-path на BACKEND)"
  echo
}

main() {
  [ "$(id -u)" -eq 0 ] || { echo "Запустите от root: sudo bash $0"; exit 1; }
  mkdir -p "$(dirname "$LOG")"
  : > "$LOG"
  TMPD=$(mktemp -d /tmp/relay-setup.XXXXXX)
  trap cleanup EXIT
  trap 'echo; warn "прервано"; exit 130' INT TERM

  banner

  preflight
  menu
  case "$MODE" in
    install_backend) run_install_backend ;;
    install_relay) run_install ;;
    test) run_test ;;
    uninstall) do_uninstall ;;
  esac
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  main "$@"
fi
