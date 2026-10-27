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
VERSION="2.1.0"
NAME="Server Setup Toolkit"

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
  echo "  Всё для серверов в одном скрипте:"
  echo "   • подготовка сервера: обновление, SSH-порт и ключ, fail2ban, автообновления"
  echo "   • Backend с 3x-ui, nginx и сертификатом (с relay или без)"
  echo "   • Relay: обратный туннель rathole (TLS), firewall, пересылка UDP"
  echo "   • тест блокировок (16 КБ, SNI, порты, UDP) и скорости между серверами"
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

# сбрасываем всё, что накопилось в буфере терминала (случайные Enter, хвост вставленного ключа),
# иначе «залежавшийся» Enter мгновенно ответит «да» на следующий вопрос
drain_tty() {
  ( : < /dev/tty ) 2>/dev/null || return 0
  local _j
  while IFS= read -r -t 0.05 -n 1 _j < /dev/tty; do :; done
}

confirm() {  # Enter / y = да, n = нет
  local a
  drain_tty
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
step_run() {  # step_run [-s] "Описание" команда args...   (-s: при ошибке только предупреждение)
  local soft=0
  if [ "${1:-}" = "-s" ]; then soft=1; shift; fi
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
  elif [ $soft -eq 1 ]; then
    warn "$label — пропущено"
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
  if [ -f "$PREP_MARKER_FILE" ]; then
    info "подготовка сервера уже выполнена: $(awk -F= '/^ran_at=/{print $2}' "$PREP_MARKER_FILE"), SSH-порт $(awk -F= '/^ssh_port=/{print $2}' "$PREP_MARKER_FILE") (повторный выбор пункта 1 предложит откат)"
  fi
  if [ $has -eq 1 ]; then
    k=$(marker_get KIND); k="${k:-relay}"
    info "найдена метка установки: $(marker_get INSTALLED_AT), статус: $(marker_get STATUS), режим: $k, сервер $(marker_get BACKEND_IP), домен $(marker_get DOMAIN)"
  fi
  echo "  ${B}1${R}. Подготовить сервер"
  echo "  ${B}2${R}. Установить и настроить Backend сервер с 3X-UI панелью (без relay)"
  echo "  ${B}3${R}. Установить и настроить Relay + Backend сервер с 3X-UI панелью"
  echo "  ${B}4${R}. Протестировать BACKEND сервер"
  [ $has -eq 1 ] && echo "  ${B}5${R}. Отменить установку (удалить всё)"
  while true; do
    rd -r -p "${B}?${R} Выберите вариант: " c
    case "$c" in
      1) MODE="prepare"; return 0 ;;
      2) MODE="install_backend"; return 0 ;;
      3) MODE="install_relay"; return 0 ;;
      4) MODE="test"; return 0 ;;
      5) if [ $has -eq 1 ]; then MODE="uninstall"; return 0; fi; fail "вариант 5 доступен только после установки" ;;
      *) if [ $has -eq 1 ]; then fail "введите от 1 до 5"; else fail "введите от 1 до 4"; fi ;;
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
  rscript "$TMPD/f2b-ignore.sh" "$RELAY_IP" >>"$LOG" 2>&1 || true

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


  # Встроенный генератор Honeypot: исходник хранится в читаемом виде без сжатия.
  cat > "$D/honeypot-generator.source.sh" <<'__HONEYPOT_GENERATOR_SOURCE_20261027__'
#!/bin/bash
set -e

# ============================================================
#  Honeypot generator v.0.4
#  Генерация случайного сайта-визитки + nginx + Let's Encrypt
#
#  Использование:
#    ./honeypot-generator.sh [домен]
#
#  Переменные окружения (необязательно):
#    HONEYPOT_SEED=12345     повторить ранее сгенерированный сайт
#    HONEYPOT_DRYRUN=1       только сгенерировать файлы сайта
#                            (без apt / nginx / certbot, root не нужен)
#    HONEYPOT_WEBROOT=/path  каталог сайта (по умолчанию /var/www/honeypot)
# ============================================================

WEBROOT=""
NGINX_AVAILABLE="/etc/nginx/sites-available"
NGINX_ENABLED="/etc/nginx/sites-enabled"
DRY_RUN="${HONEYPOT_DRYRUN:-0}"
C_RESET="\\033[0m"; C_CYAN="\\033[36m"; C_GREEN="\\033[32m"; C_YELLOW="\\033[33m"; C_RED="\\033[31m"; C_BOLD="\\033[1m"
if [[ -t 1 ]]; then COLOR=1; else COLOR=0; fi
paint(){ if [ "$COLOR" -eq 1 ]; then printf '%b%s%b\n' "$1" "$2" "$C_RESET"; else printf '%s\n' "$2"; fi; }
line(){ printf '%s\n' '━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━'; }
step(){ if [ "$COLOR" -eq 1 ]; then printf '\n%b▶ %s%b\n' "$C_CYAN$C_BOLD" "$1" "$C_RESET"; else printf '\n▶ %s\n' "$1"; fi; }

if [ "$DRY_RUN" != "1" ] && [ "$(id -u)" -ne 0 ]; then
    echo "Запустите скрипт от root (sudo)."
    exit 1
fi

DOMAIN="${1:-}"

if [ -z "$DOMAIN" ]; then
    [[ -t 1 ]] && clear
    paint "$C_CYAN$C_BOLD" "╭────────────────────────────────────────────────────────────╮"
    paint "$C_CYAN$C_BOLD" "│                 HONEYPOT GENERATOR v0.4                    │"
    paint "$C_CYAN$C_BOLD" "╰────────────────────────────────────────────────────────────╯"
    echo "  Генерация сайта • безопасная настройка nginx • HTTPS"
    echo
    read -rp "  Домен (например site.example.com): " DOMAIN
fi

DOMAIN="${DOMAIN,,}"
if [ -z "$DOMAIN" ]; then
    echo "Домен не может быть пустым."
    exit 1
fi
if ! [[ "$DOMAIN" =~ ^[a-z0-9]([a-z0-9.-]*[a-z0-9])?\.[a-z]{2,}$ ]]; then
    echo "Некорректный домен: $DOMAIN"
    exit 1
fi

WEBROOT="${HONEYPOT_WEBROOT:-/var/www/honeypot/$DOMAIN}"
step "1/6  Проверка окружения"
printf "  Домен:     %s\\n  Каталог:   %s\\n  Режим:     %s\\n" "$DOMAIN" "$WEBROOT" "$([ "$DRY_RUN" = "1" ] && echo "dry-run" || echo "установка")"
if [ "$DRY_RUN" != "1" ]; then
    if ! command -v apt-get >/dev/null 2>&1 || ! command -v systemctl >/dev/null 2>&1; then
        paint "$C_RED" "✖ Ожидается Debian/Ubuntu с apt-get и systemd."
        exit 1
    fi
    # ---------- поиск следов ранее настроенного домена ----------
    NGINX_CONFD="/etc/nginx/conf.d"
    LE_DIR="/etc/letsencrypt"
    RENEW_SCRIPT="/usr/local/bin/renew-${DOMAIN}.sh"
    RENEW_LOG="/var/log/renew-${DOMAIN}.log"
    DEFAULT_WEBROOT="/var/www/honeypot/${DOMAIN}"
    DOMAIN_RE="${DOMAIN//./\\.}"
    NGINX_HITS=(); DEL_NGINX=(); BLOCKED=(); CERT_PATHS=(); CERT_NAMES=()
    HAS_WEBROOT=0; HAS_RENEW=0; HAS_CRON=0

    add_uniq() {
        local -n _arr="$1"
        local x
        for x in "${_arr[@]}"; do
            if [ "$x" = "$2" ]; then return 0; fi
        done
        _arr+=("$2")
    }
    # 0, если в server_name файла нет никаких доменов, кроме $2
    only_this_domain() {
        local other
        other="$(grep -hE '^[[:space:]]*server_name[[:space:]]' "$1" 2>/dev/null \
            | sed -E 's/#.*//; s/^[[:space:]]*server_name[[:space:]]+//; s/;.*//' \
            | tr -s ' \t' '\n\n' | grep -v '^$' | grep -vxF "$2" || true)"
        [ -z "$other" ]
    }

    # 1) nginx: конфиги с именем домена, симлинки на них и любые файлы с этим server_name
    for _f in "$NGINX_AVAILABLE/${DOMAIN}.conf" "$NGINX_ENABLED/${DOMAIN}.conf" "$NGINX_CONFD/${DOMAIN}.conf"; do
        if [ -e "$_f" ] || [ -L "$_f" ]; then add_uniq NGINX_HITS "$_f"; fi
    done
    if [ -d "$NGINX_ENABLED" ]; then
        _exact_real="$(readlink -f "$NGINX_AVAILABLE/${DOMAIN}.conf" 2>/dev/null || true)"
        for _f in "$NGINX_ENABLED"/*; do
            if [ -L "$_f" ] && [ "$(readlink -f "$_f" 2>/dev/null || true)" = "$_exact_real" ]; then
                add_uniq NGINX_HITS "$_f"
            fi
        done
    fi
    _dirs=()
    for _d in "$NGINX_AVAILABLE" "$NGINX_ENABLED" "$NGINX_CONFD"; do
        if [ -d "$_d" ]; then _dirs+=("$_d"); fi
    done
    if [ "${#_dirs[@]}" -gt 0 ]; then
        while IFS= read -r _f; do
            if [ -n "$_f" ]; then add_uniq NGINX_HITS "$_f"; fi
        done < <(grep -RIlE "^[[:space:]]*server_name[[:space:]]([^;]*[[:space:]])?${DOMAIN_RE}[[:space:];]" "${_dirs[@]}" 2>/dev/null || true)
    fi
    for _f in "${NGINX_HITS[@]}"; do
        if [ -L "$_f" ] && [ ! -e "$_f" ]; then
            add_uniq DEL_NGINX "$_f"                  # битая ссылка
        elif only_this_domain "$_f" "$DOMAIN"; then
            add_uniq DEL_NGINX "$_f"
        else
            add_uniq BLOCKED "$_f"                    # в файле есть другие домены
        fi
    done
    if [ "${#BLOCKED[@]}" -gt 0 ]; then
        paint "$C_RED" "✖ Домен указан в конфигурации nginx вместе с другими доменами:"
        printf '    %s\n' "${BLOCKED[@]}"
        echo "  Автоматическое удаление небезопасно. Уберите домен из server_name вручную и запустите скрипт снова."
        exit 1
    fi

    # 2) сертификаты Let's Encrypt (live / archive / renewal)
    for _p in "$LE_DIR/live/${DOMAIN}" "$LE_DIR"/live/"${DOMAIN}"-[0-9][0-9][0-9][0-9] \
              "$LE_DIR/archive/${DOMAIN}" "$LE_DIR"/archive/"${DOMAIN}"-[0-9][0-9][0-9][0-9] \
              "$LE_DIR/renewal/${DOMAIN}.conf" "$LE_DIR"/renewal/"${DOMAIN}"-[0-9][0-9][0-9][0-9].conf; do
        if [ -e "$_p" ] || [ -L "$_p" ]; then
            add_uniq CERT_PATHS "$_p"
            _n="$(basename "$_p")"
            case "$_p" in */renewal/*) _n="${_n%.conf}" ;; esac
            add_uniq CERT_NAMES "$_n"
        fi
    done

    # 3) каталог сайта, скрипт автообновления, cron
    if [ -d "$WEBROOT" ] && [ -n "$(find "$WEBROOT" -mindepth 1 -maxdepth 1 -print -quit 2>/dev/null)" ]; then HAS_WEBROOT=1; fi
    if [ -e "$RENEW_SCRIPT" ]; then HAS_RENEW=1; fi
    if crontab -l 2>/dev/null | grep -qF "$RENEW_SCRIPT"; then HAS_CRON=1; fi

    if [ $(( ${#DEL_NGINX[@]} + ${#CERT_PATHS[@]} + HAS_WEBROOT + HAS_RENEW + HAS_CRON )) -gt 0 ]; then
        paint "$C_YELLOW" "⚠ Домен уже настраивался на этом сервере. Найдено:"
        for _f in "${DEL_NGINX[@]}"; do echo "    nginx:        $_f"; done
        for _p in "${CERT_PATHS[@]}"; do echo "    сертификат:   $_p"; done
        if [ "$HAS_WEBROOT" -eq 1 ]; then
            if [ "$WEBROOT" = "$DEFAULT_WEBROOT" ]; then
                echo "    каталог:      $WEBROOT"
            else
                echo "    каталог:      $WEBROOT (нестандартный путь — удалён не будет, файлы будут перезаписаны)"
            fi
        fi
        if [ "$HAS_RENEW" -eq 1 ]; then echo "    автообновление: $RENEW_SCRIPT"; fi
        if [ "$HAS_CRON" -eq 1 ]; then echo "    cron:         задание для $RENEW_SCRIPT"; fi
        echo

        while :; do
            if ! read -rp "  Удалить конфигурацию для этого домена и создать заново? [Y/n] (Enter = да): " ANSWER; then
                echo; echo "Отменено."; exit 1
            fi
            case "$ANSWER" in
                ""|y|Y|yes|YES|Yes|д|Д|да|Да|ДА) break ;;
                n|N|no|NO|No|н|Н|нет|Нет|НЕТ) echo "Отменено. Ничего не изменено."; exit 0 ;;
                *) echo "  Введите y или n (Enter = да)." ;;
            esac
        done

        # --- удаление: nginx (сначала ссылки, затем сами конфиги) ---
        for _f in "${DEL_NGINX[@]}"; do
            if [ -L "$_f" ]; then rm -f -- "$_f"; fi
        done
        for _f in "${DEL_NGINX[@]}"; do
            rm -f -- "$_f"
        done
        # --- сертификаты: штатно через certbot, запасной вариант — вручную ---
        for _n in "${CERT_NAMES[@]}"; do
            if command -v certbot >/dev/null 2>&1; then
                certbot delete --cert-name "$_n" --non-interactive >/dev/null 2>&1 || true
            fi
            rm -rf -- "$LE_DIR/live/$_n" "$LE_DIR/archive/$_n" "$LE_DIR/renewal/$_n.conf"
        done
        # --- автообновление и cron ---
        if [ "$HAS_CRON" -eq 1 ]; then
            ( crontab -l 2>/dev/null | grep -vF "$RENEW_SCRIPT" || true ) | crontab -
        fi
        rm -f -- "$RENEW_SCRIPT" "$RENEW_LOG"
        # --- каталог сайта: только стандартный путь /var/www/honeypot/<домен> ---
        if [ "$WEBROOT" = "$DEFAULT_WEBROOT" ] && [ -d "$WEBROOT" ]; then
            rm -rf -- "$WEBROOT"
        fi
        # --- применить удаление в работающем nginx ---
        if [ "${#DEL_NGINX[@]}" -gt 0 ] && command -v nginx >/dev/null 2>&1 && nginx -t >/dev/null 2>&1; then
            systemctl reload nginx >/dev/null 2>&1 || true
        fi
        paint "$C_GREEN" "  ✓ Старая конфигурация удалена, создаю заново."
    fi
fi

# ------------------------------------------------------------
# Проверка и установка зависимостей
# ------------------------------------------------------------
if [ "$DRY_RUN" != "1" ]; then
    step "2/6  Проверка и установка зависимостей"

    export DEBIAN_FRONTEND=noninteractive
    APT_UPDATED=0

    install_if_missing() {
        local pkg="$1"
        if ! dpkg -s "$pkg" >/dev/null 2>&1; then
            echo "  -> $pkg не найден, устанавливаю..."
            if [ "$APT_UPDATED" -eq 0 ]; then
                apt-get update -qq
                APT_UPDATED=1
            fi
            apt-get install -y "$pkg"
        else
            echo "  -> $pkg уже установлен"
        fi
    }

    install_if_missing nginx
    install_if_missing certbot
    install_if_missing python3-certbot-nginx
    mkdir -p /var/www/certbot
fi

mkdir -p "$WEBROOT"

# ============================================================
#  ГЕНЕРАТОР САЙТА
# ============================================================
step "3/6  Генерация сайта"

# ---------- сид (для воспроизводимости) ----------
SEED="${HONEYPOT_SEED:-$(( (RANDOM << 15) | RANDOM ))}"
RANDOM=$SEED

# ---------- помощники (без подоболочек, чтобы сид работал корректно) ----------
LETTERS=ABCDEFGHIJKLMNOPQRSTUVWXYZ
CA_LETTERS=ABCEGHJKLMNPRSTVWXYZ
R=""
rnd()    { R=$(( $1 + RANDOM % ($2 - $1 + 1) )); }
chance() { if (( RANDOM % 100 < $1 )); then R=1; else R=0; fi; }
pick()   { local -n _pa=$1; R="${_pa[RANDOM % ${#_pa[@]}]}"; }
shuffle() {
    local -n _sa=$1
    local i j t
    for (( i=${#_sa[@]}-1; i>0; i-- )); do
        j=$(( RANDOM % (i+1) ))
        t="${_sa[i]}"; _sa[i]="${_sa[j]}"; _sa[j]="$t"
    done
}
fmt_fill() {   # N цифра, L буква, P буква (CA), строчная буква = литерал, остальное как есть
    local f="$1" out="" c i
    for (( i=0; i<${#f}; i++ )); do
        c="${f:i:1}"
        case "$c" in
            N) out+=$(( RANDOM % 10 )) ;;
            L) out+="${LETTERS:RANDOM%26:1}" ;;
            P) out+="${CA_LETTERS:RANDOM%20:1}" ;;
            [[:lower:]]) out+="${c^^}" ;;
            *) out+="$c" ;;
        esac
    done
    R="$out"
}
html_esc() {
    local s="$1"
    s="${s//&/&amp;}"; s="${s//</&lt;}"; s="${s//>/&gt;}"; s="${s//\"/&quot;}"
    R="$s"
}
hsl2hex() {
    awk -v h="$1" -v s="$2" -v l="$3" '
    function mn(a,b){return a<b?a:b}
    function mx(a,b){return a>b?a:b}
    function f(n,  k,a,t){k=(n+h/30)%12; a=(s/100)*mn(l/100,1-l/100);
        t=mx(-1,mn(mn(k-3,9-k),1)); return int((l/100-a*t)*255+0.5)}
    BEGIN{printf "#%02x%02x%02x",f(0),f(8),f(4)}'
}

CUR_YEAR=$(date +%Y)

# ============================================================
#  ПУЛЫ ДАННЫХ И ГЕНЕРАТОРЫ
#  Готовых предложений в коде нет: тексты собираются из шаблонов
#  по токенам @NAME@ (см. expand), слова берутся из словарей P_NAME.
#  Словари содержат только слова и короткие фразы по тематике.
# ============================================================

# ---------- общие словари (не зависят от тематики) ----------
P_SIZE=("a small" "an independent" "a friendly" "a close-knit" "an experienced" "a dedicated")
P_QUAL=("with care" "on schedule" "in a clear, structured way" "step by step" "without surprises" "to a clear brief" "with attention to detail" "on time and on budget")
P_DELIV=(delivered handled provided managed)
P_TRAIT=(calm direct thorough responsive friendly reliable patient honest professional practical "well prepared" "easy to work with")
P_TRUST=(trust recommend)
P_REF=(recommendation referrals "word of mouth")
P_EXP=("a pleasure" "refreshingly straightforward" "easy from the first call" "a real relief" "far easier than we expected")
P_QRES=("better than we expected" "exactly what we needed" "delivered on time" "clear and easy to follow" "a real improvement for our team" "handled with great care")
P_RECO=(recommend "happily recommend" "gladly recommend" "highly recommend")
P_LEADIN=("You can count on us to" "Our team will" "Expect us to" "We are here to")
P_LISTEN=("learning about" "looking closely at" "getting to know" "reviewing" "asking about")
P_ST1=(Discover Listen Brief Introduction Scope)
P_ST2=(Plan Assess Review Propose)
P_ST3=(Deliver Implement Execute Produce)
P_ST4=(Support Follow-up Handover Aftercare)
P_SMALL=(small simple urgent routine)
P_LARGE=(large complex long-term ambitious)
P_PADJ=(simple clear transparent straightforward)
P_INFORMED=(informed "up to date" "on the same page" "in the loop")
P_FIRSTW=(call conversation meeting enquiry)
P_LASTW=(delivery handover review sign-off)
P_KIND=("A few words" "Some kind words" "Feedback" "Comments")
P_LUCKY=(lucky grateful fortunate)
P_GIVE=("are generous with their feedback" "share their experience openly" "tell us honestly what they think")
P_CVERB=("Call, write or drop by" "Tell us about your project" "Get in touch whenever it suits you" "Send us a message or give us a call")
P_REPLY=("We usually reply" "We aim to reply" "You will normally hear back")
P_DAYS=("one working day" "a day" "24 hours" "two working days")

# ---------- шаблоны текста ----------
HERO_TPL=("@HADJ@ @HNOUN@ for @WHO@" "@HNOUN@ that @HTAIL@" "@HNOUN@ you can @TRUST@")
TAG_TPL=("@HADJ@ @HNOUN@, @DELIV@ @QUAL@." "@HNOUN@ for @WHO@, @DELIV@ @QUAL@." "@SIZE@ @TEAM@ of @PRO@, focused on @CARE@.")
LEAD_TPL=(
 "We @ACT@, @ACT2@ and @ACT3@ for @WHO@."
 "@SIZE@ @TEAM@ of @PRO@ who @ACT@ and @ACT2@, @QUAL@."
 "We help @WHO@ @GOAL@ and @GOAL2@, @QUAL@."
 "From the first @FIRSTW@ to the final @LASTW@, we @ACT@ and @ACT2@ for @WHO@."
)
AS_ID=(
 "We are @SIZE@ @TEAM@ of @PRO@ who care about @CARE@, @CARE2@ and @CARE3@."
 "Our @TEAM@ of @PRO@ is focused on @CARE@, and we @ACT@ for @WHO@."
 "We are @SIZE@ @TEAM@ of @PRO@, and we @ACT@ for @WHO@."
)
AS_CL=(
 "Most of our clients come to us through @REF@, and many have stayed with us for years."
 "Our clients include @CLIENT@, @CLIENT2@ and @CLIENT3@."
 "We work with @CLIENT@ and @CLIENT2@, and most of them find us through @REF@."
)
AS_WORK=(
 "Each project starts with a conversation about your @OBJ@ and ends with @OUT@."
 "We keep our team deliberately small, so the people you meet first are the people who @ACT@ and @ACT2@."
 "Whatever the size of the job, you deal directly with the @PRO@ responsible for it."
 "We @ACT@, @ACT2@ and @ACT3@, always @QUAL@."
 "You can expect us to @ACT@ @QUAL@, and to @ACT2@ without fuss."
)
ABOUT_LOC_TPL=(
 "Founded in @YEAR@ and based in @CITY@, we work with @CLIENT@, @CLIENT2@ and @CLIENT3@ across @COUNTRYTHE@."
 "Since @YEAR@ we have been working from @CITY@, helping @CLIENT@ and @CLIENT2@ across @COUNTRYTHE@ and beyond."
 "Our office in @CITY@ has been home to the team since @YEAR@, and we work with clients locally and across @COUNTRYTHE@."
)
P_SVCTPL=(
 "We @ACT@ and @ACT2@, @QUAL@."
 "@LEADIN@ @ACT@ and @ACT2@."
 "A practical service for @WHO@: we @ACT@, then @ACT2@."
 "We help @WHO@ @GOAL@, and we @ACT@ @QUAL@."
 "Our @PRO@ @ACT@, @QUAL@, from the first @FIRSTW@ to the final @LASTW@."
 "We help @WHO@ @GOAL@ and @GOAL2@, @QUAL@."
)
PT_S1=("We start by @LISTEN@ your @OBJ@, so we understand what a good result looks like." "We begin with a conversation about your @OBJ@ and @OBJ2@.")
PT_S2=("We @ACT@ and share what we find, @QUAL@." "A specialist team will @ACT@ and @ACT2@.")
PT_S3=("You receive @OUT@, prepared @QUAL@." "We deliver @OUT@, ready for you to use.")
PT_S4=("We stay involved after delivery to @ACT@ as your needs change." "You keep the same contact, who will @ACT@ whenever you need us.")
QT_TPL=(
 "They @DONE@ and the result was @QRES@."
 "They were @TRAIT@, @TRAIT2@ and @TRAIT3@ from the first @FIRSTW@ to the final @LASTW@. We would @RECO@ them to anyone who needs help with their @OBJ@."
 "Working with them was @EXP@. They @DONE@ and @DONE2@."
 "We have worked with them more than once. Each time they @DONE@, and the invoice matched the quote."
)
SUBSVC_TPL=("Here is how we can help @WHO@." "Whether the need is @SMALL@ or @LARGE@, we shape the work around you." "A focused set of services for @WHO@, @DELIV@ @QUAL@.")
SUBPROC_TPL=("A @PADJ@ process that keeps everyone @INFORMED@." "No surprises, just clear steps from the first @FIRSTW@ to the final @LASTW@.")
SUBQ_TPL=("@KIND@ from people we have worked with." "We are @LUCKY@ to work with clients who @GIVE@.")
SUBC_TPL=("@CVERB@. @REPLY@ within @DAYS@." "@REPLY@ within @DAYS@. @CVERB@.")

# ---------- значения (название|варианты фраз после «We») ----------
VALUES=(
 "Plain language|explain things clearly|avoid jargon|write in plain English|keep every message easy to follow"
 "Honest estimates|quote fairly|agree prices in advance|flag changes before they cost you|keep invoices in line with quotes"
 "Direct access|put you in touch with the people doing the work|keep one named contact for every project|answer your calls ourselves"
 "Long-term thinking|aim for results that last|think beyond the first project|look after clients for years"
 "Careful delivery|respect deadlines|check the details twice|keep everyone informed along the way"
 "Fair pricing|keep our fees clear|agree costs in advance|avoid hidden extras"
 "Discretion|keep your information confidential|treat every project as private|share details only when needed"
 "Responsiveness|reply within one working day|answer messages promptly|keep you updated as work progresses"
)

H_ABOUT=("About us" "Who we are" "Our story" "A little about us")
H_SVC=("Services" "What we do" "How we can help" "Our expertise" "What we offer")
H_PROC=("How we work" "Our approach" "Working together" "The process")
H_QUOTES=("What clients say" "Client feedback" "Kind words" "In their words")
H_CONTACT=("Get in touch" "Contact us" "Let's talk" "Visit or write to us")
CTA_NAV=("Contact us" "Get in touch" "Talk to us" "Request a call")
CTA_HERO1=("Get in touch" "Start a conversation" "Request a quote" "Book an introductory call")
CTA_HERO2=("See our services" "What we do" "Explore services" "Learn more")

# ---------- словари для имён, адресов, часов ----------
FIRST=(Anna James Maria Daniel Sofia Liam Elena Marcus Priya Thomas Hannah Omar Claire Lucas Nina Peter Grace Samuel Julia Victor Amara Ethan Clara Felix Isla Noah Maya Oliver Leila Henry Zoe Adam Rosa Jonas Tessa Owen Mira Callum Freya Ravi Ingrid Joel Dana Hugo Esme Kai Lena Theo)
ROLES=("Managing Director" "Operations Manager" "Founder" "Head of Finance" "Project Lead" "Office Manager" "Product Owner" "Marketing Director" "Owner" "Head of Operations" "Partner")
ORG_NOUN=(Foods Dental Housing Retail Farms Clinic Energy Hotels Electronics Bakery Engineering Textiles Media Publishing Dairy Pharmacy Motors Interiors)
SN_STEM=(Hart Ash Whit Brook Cal Fen Kings Mar Ridge Stan Thorn Wood Ellis Har Lind Pres Sut Bren Del Hol Alder Fair Green Hill Long Mer Nor Oak Pen Rob Sand Strat Tay Wal Win Ember Cross Rowan)
SN_END=(ley ford ton well wick field more man worth son ham by den ward ridge)
BR_ON=(b d f g h k l m n p r s t v z br dr fl gr kr pr tr)
BR_VO=(a e i o u)
BR_CO=("" "" n r l s m x)
BR_EN=(a o is on ia um ar en ix el)
WORDS=(Nord Vela Lumen Aster Vero Arcus Solace Pelago Meridian Orbit Cobalt Juniper Beacon Quarry Tern Alba Kestrel Linden Marlow Corvus Tallis Halden Oriel Verity)
PRE=(North West Iron Clear Silver Fox Birch Cedar Elm Oak Lark Tide Bright Green Grey Red Pine Wren Ash Summer Harbor Mill)
POST=(field wood stone light well bridge gate path ridge brook point haven line vale)
ST_STEM=(Maple Harbor Mill Park King Queen Church Station Elm Victoria Bridge Orchard Cedar Market Lake Grove Albert Willow Meadow Hill River High)
ST_TYPE=(Street Road Avenue Lane Way Square Court)
NL_STEM=(Kerk Molen Linden Haven Markt Bloem Oranje Konings Zuider Noorder Dijk Beuk Wilgen Prins)
NL_SUF=(straat laan weg gracht)
UNIT_KIND=(Suite Unit)
EMAIL_LOCALS=(info hello contact office mail team enquiries)
HR_DAYS=("Mon–Fri" "Monday to Friday" "Weekdays")
HR_MIN=(00 30)

# ---------- темы: словари по отрасли ----------
# P_HADJ/P_HNOUN — заголовки; P_ACT — «we ...» (инфинитив с объектом);
# P_GOAL — «help X ...»; P_OBJ — «your ...»; P_OUT — результат с артиклем;
# P_TOPIC × P_FORM и P_SOLO — названия услуг; P_DONE — прошедшее время для отзывов.
theme_consulting() {
  T_KEY=consulting; T_INDUSTRY="management consultancy"; T_SCHEMA=ProfessionalService
  T_SUFFIX=(Consulting Advisory Partners Group)
  P_HADJ=(Clear Practical Independent Honest Careful); P_HNOUN=(advice thinking planning support analysis)
  P_HTAIL=("turns into results" "keeps projects on track" "your team can follow" "survives contact with reality")
  P_WHO=("growing businesses" "owners and managers" "small and mid-sized companies" "leadership teams" "ambitious organizations")
  P_PRO=(advisers consultants "business analysts"); P_TEAM=(team group)
  P_CARE=("practical results" "clear communication" "honest advice" "long-term relationships" "getting the details right" "plain language")
  P_ACT=("untangle complex decisions" "review how the business runs" "map your priorities and risks" "plan the next stage of growth" "tighten processes and reporting" "agree realistic goals and timelines" "bring leadership teams to a shared view" "identify where costs can come down" "turn strategy into a delivery plan" "support teams through change" "benchmark performance against the market" "prepare boards and investors for key decisions")
  P_GOAL=("make confident decisions" "focus on what matters most" "plan growth with fewer surprises" "run more efficiently" "bring teams together behind one plan" "manage change without disruption")
  P_OBJ=(priorities processes goals plans challenges costs)
  P_OUT=("a short, prioritized plan" "a clear set of recommendations" "a practical roadmap" "a candid written assessment" "a realistic budget and timeline")
  P_CLIENT=("family businesses" start-ups manufacturers "local charities" retailers schools "professional firms" "housing associations")
  P_TOPIC=(Strategy Operations Change Market Project Performance Growth Risk); P_FORM=(review planning support advisory workshops)
  P_SOLO=("Management coaching" "Executive workshops" "Due diligence support")
  P_DONE=("reviewed how our business runs" "untangled a difficult decision for us" "built a plan we could actually follow" "brought our leadership team onto the same page" "found savings we had missed" "guided us through a major change")
  T_STATS=("Projects delivered|80|420" "Clients advised|40|180")
}
theme_design() {
  T_KEY=design; T_INDUSTRY="design studio"; T_SCHEMA=ProfessionalService
  T_SUFFIX=(Studio Design "Design Studio" Creative)
  P_HADJ=(Thoughtful Considered Distinctive Clear Honest); P_HNOUN=(design branding "visual identity" "web design")
  P_HTAIL=("earns its place" "people remember" "lasts for years" "works as hard as you do")
  P_WHO=("ambitious brands" "small and mid-sized organizations" "founders and cultural organizations" "growing businesses" "independent companies")
  P_PRO=(designers "designers and developers" "designers and art directors"); P_TEAM=(studio team)
  P_CARE=(clarity craft "making things useful first" "getting every detail right" "work that lasts" "honest feedback")
  P_ACT=("design identities that grow with you" "shape brand guidelines your team can use" "design websites that are easy to maintain" "lay out reports and printed materials" "direct photography and campaigns" "develop clear visual systems" "turn rough ideas into finished work" "refine logos, type and color" "prepare final files for print and web" "design packaging that works on the shelf" "present ideas with clear reasoning" "test layouts with real content")
  P_GOAL=("look as good as they work" "stand out for the right reasons" "explain what they do more clearly" "present themselves consistently" "launch with confidence")
  P_OBJ=(audience goals content ideas "brand history" preferences)
  P_OUT=("a small number of well-developed directions" "a complete set of brand guidelines" "polished, production-ready files" "a clear visual direction" "a site design ready for build")
  P_CLIENT=(founders "cultural organizations" "local businesses" publishers restaurants charities "technology companies" architects)
  P_TOPIC=(Brand Website Packaging Editorial Print Campaign Product Identity); P_FORM=(design direction workshops)
  P_SOLO=("Design systems" "Art direction" "Logo and type design" "Photography direction")
  P_DONE=("turned a vague brief into an identity we are proud of" "redesigned our website from the ground up" "made our printed material look far better" "gave our brand a clear and consistent look" "rebuilt our packaging from scratch" "listened carefully and got the tone exactly right")
  T_STATS=("Brands launched|45|260" "Websites shipped|60|310")
}
theme_architecture() {
  T_KEY=architecture; T_INDUSTRY="architecture and interiors practice"; T_SCHEMA=ProfessionalService
  T_SUFFIX=(Architects "Architecture Studio" "Design Office" Interiors)
  P_HADJ=(Considered Thoughtful Sustainable Practical Careful); P_HNOUN=(architecture "interior design" "residential design" "building design")
  P_HTAIL=("fits the way you live" "is shaped by light and place" "stands up to daily use")
  P_WHO=("families and homeowners" "growing businesses" "private clients" "developers and landlords" "people who care about their space")
  P_PRO=(architects "architects and interior designers" "architects and designers"); P_TEAM=(practice studio)
  P_CARE=("light and proportion" "listening before drawing" "buildings that last" "getting the details right" "practical, buildable design")
  P_ACT=("design homes, extensions and renovations" "plan interiors around how you live" "prepare and submit planning applications" "advise on what a site can offer" "detail drawings so builders can price with confidence" "supervise construction on site" "select materials and lighting" "guide projects through planning and building control" "test ideas with sketches and models" "coordinate engineers and consultants" "check the work against the drawings" "keep the project on budget")
  P_GOAL=("make the most of their space" "build with confidence" "turn a site into a home" "get planning approval with fewer surprises" "stay on budget during construction")
  P_OBJ=(site brief budget timeline ideas "planning constraints")
  P_OUT=("concept sketches and models" "a full set of detailed drawings" "a clear planning submission" "an honest feasibility report" "a specification builders can price")
  P_CLIENT=(homeowners developers "local businesses" schools landlords "restaurants and shops" "housing associations" "cultural venues")
  P_TOPIC=(Residential Commercial Interior Heritage Extension Retail Workplace Landscape); P_FORM=(design consultancy planning supervision)
  P_SOLO=("Feasibility studies" "Planning applications" "Site supervision" "Building surveys")
  P_DONE=("turned a dark, awkward house into a bright home" "guided us through planning without any drama" "kept the build on budget" "designed a space that works for how we live" "explained every drawing patiently")
  T_STATS=("Buildings completed|30|140" "Planning approvals|40|190")
}
theme_accounting() {
  T_KEY=accounting; T_INDUSTRY="accounting and tax advisory firm"; T_SCHEMA=AccountingService
  T_SUFFIX=(Accountants "Tax Advisory" "Financial Services" "& Co.")
  P_HADJ=(Dependable Straightforward Accurate Personal Careful); P_HNOUN=(accounting "tax advice" bookkeeping "financial support" "business advice")
  P_HTAIL=("keeps you on top of deadlines" "explains the numbers clearly" "saves time every month" "grows with your business")
  P_WHO=("small businesses" "self-employed professionals" "families and owners" "start-ups and freelancers" "growing companies")
  P_PRO=(accountants "accountants and tax advisers" "bookkeepers and accountants"); P_TEAM=(practice team)
  P_CARE=(accuracy "meeting deadlines" "plain language" "long-term relationships" "keeping things simple")
  P_ACT=("prepare annual accounts and tax returns" "keep your records accurate and up to date" "plan tax sensibly and within the rules" "run payroll and pensions" "handle sales tax and VAT returns" "build budgets and forecasts" "answer questions promptly and clearly" "spot savings and deadlines early" "reconcile accounts every month" "prepare management reports" "advise on the right business structure" "deal with the tax authorities on your behalf")
  P_GOAL=("keep on top of their finances" "pay no more tax than they need to" "meet every filing deadline" "understand their numbers" "plan for the year ahead")
  P_OBJ=(records "tax position" deadlines "cash flow" "business goals" paperwork)
  P_OUT=("accurate, filed accounts" "a clear summary of your tax position" "a simple calendar of deadlines" "a budget you can work to" "regular management reports")
  P_CLIENT=("sole traders" "family businesses" landlords start-ups freelancers charities contractors "professional practices")
  P_TOPIC=(Business Personal Corporate Property Startup Contractor); P_FORM=("tax planning" accounts bookkeeping advisory compliance)
  P_SOLO=(Payroll "Annual accounts" "Sales tax and VAT" "Financial forecasting")
  P_DONE=("sorted out our accounts after years of stress" "saved us a considerable amount in tax" "explained our options in plain English" "kept every deadline without reminders" "set up a bookkeeping routine that works")
  T_STATS=("Clients served|120|650" "Returns filed each year|300|1900")
}
theme_software() {
  T_KEY=software; T_INDUSTRY="software development company"; T_SCHEMA=Organization
  T_SUFFIX=(Labs Software Systems Digital Works)
  P_HADJ=(Reliable Practical Maintainable Secure Clean); P_HNOUN=("software engineering" "web development" "app development" "custom software")
  P_HTAIL=("your team can maintain" "is built to last" "ships every few weeks" "stays out of your way")
  P_WHO=("growing teams" "startups and established companies" "ambitious organizations" "product teams" "small and mid-sized businesses")
  P_PRO=(engineers "engineers and designers" developers); P_TEAM=(team group)
  P_CARE=("clean code" "honest estimates" "regular releases" "software that lasts" "keeping things simple")
  P_ACT=("build web and mobile applications" "connect your existing tools and data" "modernize legacy systems carefully" "set up reliable deployment pipelines" "review architecture and code quality" "test thoroughly before every release" "ship working software every few weeks" "monitor and maintain what we build" "document the system for your own team" "estimate the work honestly before we start" "secure applications against common attacks" "hand over clean, readable code")
  P_GOAL=("ship with confidence" "retire fragile legacy systems" "automate repetitive work" "make their data work together" "release more often with fewer surprises")
  P_OBJ=(requirements "existing systems" "technical constraints" goals deadlines "release plans")
  P_OUT=("a working first release" "a clear technical proposal" "a tested and documented system" "a realistic delivery plan" "clean, well-documented code")
  P_CLIENT=(startups "retail companies" "logistics firms" clinics schools "financial firms" agencies manufacturers)
  P_TOPIC=(Web Mobile Cloud Data Backend Frontend Cross-platform); P_FORM=(development engineering architecture testing support integration)
  P_SOLO=("API integration" "Legacy modernization" "DevOps and deployment" "Technical audits")
  P_DONE=("delivered on time with clean code" "migrated our legacy system without downtime" "built an app our customers love" "connected our tools so data flows automatically" "made our releases uneventful")
  T_STATS=("Products launched|25|130" "Integrations built|40|220")
}
theme_logistics() {
  T_KEY=logistics; T_INDUSTRY="freight and logistics company"; T_SCHEMA=Organization
  T_SUFFIX=(Logistics Freight Transport "Supply Chain" Cargo)
  P_HADJ=(Reliable Dependable Efficient Flexible Careful); P_HNOUN=(freight transport logistics "door-to-door delivery" warehousing)
  P_HTAIL=("arrives when promised" "keeps your goods moving" "is tracked from door to door" "handles the paperwork for you")
  P_WHO=("growing businesses" "importers and exporters" "manufacturers and retailers" "small and mid-sized companies" "online sellers")
  P_PRO=("logistics specialists" "freight coordinators" "transport planners"); P_TEAM=(team group)
  P_CARE=("keeping promises" "answering the phone" "reliable delivery" "clear communication" "getting goods there on time")
  P_ACT=("arrange road, sea and air freight" "handle customs clearance and paperwork" "store and pick goods in secure warehouses" "plan routes and schedules" "track every shipment" "coordinate collection and delivery" "keep you updated if anything changes" "advise on costs and carriers" "pack and label goods correctly" "book the best carrier for each load" "confirm delivery at the door" "check documents before they reach the border")
  P_GOAL=("move goods across borders" "keep delivery promises" "cut transport costs" "clear customs without delays" "ship with fewer surprises")
  P_OBJ=("delivery needs" volumes routes deadlines "shipping requirements" destinations)
  P_OUT=("a clear price for the whole journey" "tracking for every shipment" "proof of delivery sent straight to you" "a collection schedule" "complete customs documentation")
  P_CLIENT=(importers retailers manufacturers wholesalers "online sellers" "food producers" "construction firms" "furniture makers")
  P_TOPIC=(Road Sea Air Rail International Cross-border Domestic Express); P_FORM=(freight transport shipping)
  P_SOLO=("Customs clearance" Warehousing "Last-mile delivery" "Supply chain planning")
  P_DONE=("delivered everything on time" "took the customs paperwork off our hands" "told us about delays before we had to ask" "found us a cheaper route" "handled a difficult shipment calmly")
  T_STATS=("Shipments handled|900|9500" "Countries served|12|48")
}
theme_language() {
  T_KEY=language; T_INDUSTRY="translation and localization agency"; T_SCHEMA=ProfessionalService
  T_SUFFIX=(Translations Languages Linguistics "Language Services" Localization)
  P_HADJ=(Accurate Natural Careful Reliable Clear); P_HNOUN=(translation localization interpreting "language services" "technical translation")
  P_HTAIL=("sounds natural in every language" "keeps your meaning intact" "reads as if written locally" "your customers understand")
  P_WHO=("global teams" "international businesses" "law firms and manufacturers" "software companies" "importers and exporters")
  P_PRO=(linguists translators "translators and editors"); P_TEAM=(team agency)
  P_CARE=("tone as well as grammar" "getting terminology right" accuracy "meeting deadlines" "natural-sounding language")
  P_ACT=("translate documents accurately" "adapt websites for local audiences" "provide interpreters for meetings and events" "review every translation with a second linguist" "follow your preferred terminology" "deliver files in the original format" "produce certified translations" "add subtitles to videos and training material" "keep a glossary for every client" "check numbers, names and dates twice" "match the tone of the original" "work with specialists in your field")
  P_GOAL=("speak to customers in their own language" "enter new markets with confidence" "keep terminology consistent" "publish in several languages at once" "make sure nothing is lost in translation")
  P_OBJ=("source texts" terminology audience deadlines "target languages" "style preferences")
  P_OUT=("finished files in the original format" "a consistent glossary of terms" "a translation reviewed by a second linguist" "certified documents ready to submit" "a localized version ready to publish")
  P_CLIENT=("law firms" manufacturers "software companies" charities hospitals "travel companies" universities "online retailers")
  P_TOPIC=(Legal Medical Technical Website Marketing Financial Software); P_FORM=(translation localization proofreading review)
  P_SOLO=(Interpreting Subtitling "Certified translation" Transcription)
  P_DONE=("caught an error in our source text that nobody else noticed" "made our manuals consistent across every market" "delivered fast without cutting corners" "adapted our website so it feels local" "handled our legal translations without a single query")
  T_STATS=("Projects completed|300|2600" "Linguists in our network|40|220")
}
THEMES=(consulting design architecture accounting software logistics language)
pick THEMES; "theme_$R"

# ---------- страны: ISO → Название|Формы|lang|og:locale|орфография|дата|стиль улиц ----------
declare -A CINFO=(
 [US]="United States|LLC,Inc.,Corp.|en-US|en_US|us|mdy|en"
 [CA]="Canada|Inc.,Ltd.,Corp.|en-CA|en_CA|us|mdy|en"
 [GB]="United Kingdom|Ltd,LLP|en-GB|en_GB|uk|dmy|en"
 [IE]="Ireland|Ltd,DAC|en-IE|en_IE|uk|dmy|en"
 [NL]="Netherlands|B.V.,V.O.F.|en|en_GB|uk|dmy|nl"
 [SG]="Singapore|Pte. Ltd.|en-SG|en_SG|uk|dmy|en"
 [AU]="Australia|Pty Ltd|en-AU|en_AU|uk|dmy|en"
 [NZ]="New Zealand|Ltd|en-NZ|en_NZ|uk|dmy|en"
)
COUNTRY_ISOS=(US CA GB IE NL SG AU NZ)

# ---------- города: Город|Регион|ISO|Телефон|Индекс ----------
# N — цифра, L — буква, P — буква для канадских индексов, строчная буква — как есть.
# Диапазоны номеров — вымышленные (555-01xx, Ofcom drama и т. п.).
CITIES=(
 "Austin|TX|US|+1 512 555 01NN|787NN"
 "Denver|CO|US|+1 303 555 01NN|802NN"
 "Seattle|WA|US|+1 206 555 01NN|981NN"
 "Boston|MA|US|+1 617 555 01NN|021NN"
 "Chicago|IL|US|+1 312 555 01NN|606NN"
 "Atlanta|GA|US|+1 404 555 01NN|303NN"
 "Portland|OR|US|+1 503 555 01NN|972NN"
 "Miami|FL|US|+1 305 555 01NN|331NN"
 "Raleigh|NC|US|+1 919 555 01NN|276NN"
 "Minneapolis|MN|US|+1 612 555 01NN|554NN"
 "Nashville|TN|US|+1 615 555 01NN|372NN"
 "Phoenix|AZ|US|+1 602 555 01NN|850NN"
 "Toronto|ON|CA|+1 416 555 01NN|mNP NPN"
 "Vancouver|BC|CA|+1 604 555 01NN|vNP NPN"
 "Montreal|QC|CA|+1 514 555 01NN|hNP NPN"
 "Calgary|AB|CA|+1 403 555 01NN|tNP NPN"
 "Ottawa|ON|CA|+1 613 555 01NN|kNP NPN"
 "Edmonton|AB|CA|+1 780 555 01NN|tNP NPN"
 "Winnipeg|MB|CA|+1 204 555 01NN|rNP NPN"
 "Halifax|NS|CA|+1 902 555 01NN|bNP NPN"
 "London||GB|+44 20 7946 0NNN|swN NLL"
 "Manchester||GB|+44 161 496 0NNN|mN NLL"
 "Birmingham||GB|+44 121 496 0NNN|bN NLL"
 "Leeds||GB|+44 113 496 0NNN|lsN NLL"
 "Glasgow||GB|+44 141 496 0NNN|gN NLL"
 "Edinburgh||GB|+44 131 496 0NNN|ehN NLL"
 "Bristol||GB|+44 117 496 0NNN|bsN NLL"
 "Cardiff||GB|+44 29 2018 0NNN|cfNN NLL"
 "Sheffield||GB|+44 114 496 0NNN|sN NLL"
 "Liverpool||GB|+44 151 496 0NNN|lN NLL"
 "Dublin||IE|+353 1 5NN NNNN|d0N LNNN"
 "Cork||IE|+353 21 5NN NNNN|t12 LNNN"
 "Galway||IE|+353 91 5NN NNNN|h91 LNNN"
 "Limerick||IE|+353 61 5NN NNNN|v94 LNNN"
 "Waterford||IE|+353 51 5NN NNNN|x91 LNNN"
 "Amsterdam||NL|+31 20 5NN NNNN|10NN LL"
 "Rotterdam||NL|+31 10 5NN NNNN|30NN LL"
 "Utrecht||NL|+31 30 5NN NNNN|35NN LL"
 "The Hague||NL|+31 70 5NN NNNN|25NN LL"
 "Eindhoven||NL|+31 40 5NN NNNN|56NN LL"
 "Groningen||NL|+31 50 5NN NNNN|97NN LL"
 "Singapore||SG|+65 6NNN NNNN|0NNNNN"
 "Melbourne|VIC|AU|+61 3 5550 NNNN|30NN"
 "Sydney|NSW|AU|+61 2 5550 NNNN|20NN"
 "Brisbane|QLD|AU|+61 7 5550 NNNN|40NN"
 "Perth|WA|AU|+61 8 5550 NNNN|60NN"
 "Adelaide|SA|AU|+61 8 5550 NNNN|50NN"
 "Canberra|ACT|AU|+61 2 5550 NNNN|26NN"
 "Auckland||NZ|+64 9 5NN NNNN|1NNN"
 "Wellington||NZ|+64 4 5NN NNNN|6NNN"
 "Christchurch||NZ|+64 3 5NN NNNN|8NNN"
)

# ---------- страна → город → телефон/индекс/орфография ----------
pick COUNTRY_ISOS; ISO="$R"
CITY_ROWS=()
for _row in "${CITIES[@]}"; do
    case "$_row" in *"|$ISO|"*) CITY_ROWS+=("$_row") ;; esac
done
pick CITY_ROWS
IFS='|' read -r CITY REGION _iso PHONE_FMT POST_FMT <<< "$R"
IFS='|' read -r COUNTRY LEGALS LANG_CODE OG_LOCALE SPELL DATE_STYLE STREET_STYLE <<< "${CINFO[$ISO]}"
IFS=',' read -ra LEGAL_LIST <<< "$LEGALS"
pick LEGAL_LIST; LEGAL="$R"
if [ "${LEGAL: -1}" = "." ]; then LEGAL_DOT=""; else LEGAL_DOT="."; fi
case "$ISO" in GB|US|NL) COUNTRY_THE="the $COUNTRY" ;; *) COUNTRY_THE="$COUNTRY" ;; esac
fmt_fill "$PHONE_FMT"; PHONE="$R"
fmt_fill "$POST_FMT";  POST="$R"

# ---------- движок текста ----------
declare -A QI=()
# Берёт слово из словаря P_<имя> «колодой»: повторов нет, пока колода не кончится
pick_q() {
    local n="$1" i
    declare -ga "Q_$n"
    local -n _qs="P_$n" _qq="Q_$n"
    if [ "${#_qs[@]}" -eq 0 ]; then R=""; return 0; fi
    i="${QI[$n]:-}"
    if [ -z "$i" ] || [ "$i" -ge "${#_qq[@]}" ]; then
        _qq=("${_qs[@]}"); shuffle _qq; i=0
    fi
    R="${_qq[$i]}"
    QI[$n]=$(( i + 1 ))
}
# a/an по первой букве следующего слова
fix_art() {
    local -a w; local i nx
    read -ra w <<< "$1"
    for (( i=0; i<${#w[@]}-1; i++ )); do
        case "${w[i]}" in
            a|A)
                nx="${w[i+1],,}"
                case "$nx" in
                    one*|use*|uni*|eu*) ;;
                    hour*|honest*|honour*) w[i]="${w[i]}n" ;;
                    [aeiou]*) w[i]="${w[i]}n" ;;
                esac ;;
        esac
    done
    R="${w[*]}"
}
UK_MAP=("organization:organisation" "organized:organised" "organize:organise" "color:colour" "Localization:Localisation" "localization:localisation" "localized:localised" "modernization:modernisation" "modernize:modernise" "prioritized:prioritised" "specialized:specialised" "customized:customised" "analyze:analyse" "Harbor:Harbour")
spell_str() {
    local s="$1" p
    if [ "$SPELL" = uk ]; then
        for p in "${UK_MAP[@]}"; do s="${s//${p%%:*}/${p##*:}}"; done
    fi
    R="$s"
}
# Подставляет @TOKEN@ (и @TOKEN2@, @TOKEN3@) словами из P_TOKEN, затем чинит a/an и орфографию
expand() {
    local t="$1" tok base
    while [[ "$t" =~ @([A-Z]+)([0-9]*)@ ]]; do
        tok="${BASH_REMATCH[0]}"; base="${BASH_REMATCH[1]}"
        pick_q "$base"
        t="${t/"$tok"/"$R"}"
    done
    fix_art "$t"; spell_str "$R"
}
gen() { pick "$1"; expand "$R"; R="${R^}"; }   # случайный шаблон из массива → текст

# ---------- имена ----------
gen_surname() {
    local a
    pick SN_STEM; a="$R"; pick SN_END
    if [ "${a: -1}" = "${R:0:1}" ]; then R="${R:1}"; fi
    R="${a}${R}"
}
gen_brand() {
    local s v
    pick BR_ON; s="$R"; pick BR_VO; s+="$R"
    pick BR_ON; s+="$R"; pick BR_VO; s+="$R"
    chance 55
    if [ "$R" -eq 1 ]; then pick BR_EN; else pick BR_CO; fi
    s+="$R"
    R="${s^}"
}
gen_org() {
    local a
    rnd 0 2
    case "$R" in
        0) gen_brand; a="$R" ;;
        1) pick PRE; a="$R"; pick POST; a="${a}${R}" ;;
        *) gen_surname; a="$R" ;;
    esac
    pick ORG_NOUN; R="$a $R"
}

# ---------- адрес и часы ----------
gen_address() {
    local num stem typ unit="" k
    rnd 3 240; num="$R"
    if [ "$STREET_STYLE" = nl ]; then
        pick NL_STEM; stem="$R"; pick NL_SUF
        ADDR1="${stem}${R} ${num}"
        return 0
    fi
    chance 55
    if [ "$R" -eq 1 ]; then pick ST_STEM; else gen_surname; fi
    stem="$R"; pick ST_TYPE; typ="$R"
    chance 45
    if [ "$R" -eq 1 ]; then
        if [ "$ISO" = SG ]; then
            fmt_fill "#NN-NN"; unit="$R"
        else
            rnd 0 2
            if [ "$R" -eq 0 ]; then
                rnd 1 4; k="$R"
                case "$k" in 1) unit="1st Floor" ;; 2) unit="2nd Floor" ;; 3) unit="3rd Floor" ;; *) unit="4th Floor" ;; esac
            else
                pick UNIT_KIND; rnd 1 9; unit="$R"
                pick UNIT_KIND; unit="$R $unit"
            fi
        fi
    fi
    if [ -n "$unit" ]; then ADDR1="${unit}, ${num} ${stem} ${typ}"; else ADDR1="${num} ${stem} ${typ}"; fi
}
gen_hours() {
    local d oh om ch cm
    pick HR_DAYS; d="$R"
    rnd 8 9; oh="$R"; pick HR_MIN; om="$R"
    rnd 16 18; ch="$R"; pick HR_MIN; cm="$R"
    case "$ISO" in
        US|CA|AU|NZ) OPEN_HOURS="${d}, ${oh}:${om} AM – $((ch - 12)):${cm} PM" ;;
        *)           OPEN_HOURS="${d}, ${oh}:${om}–${ch}:${cm}" ;;
    esac
}

# ---------- орфография для тематических полей ----------
spell_str "$T_INDUSTRY"; T_INDUSTRY="$R"
for _i in "${!T_SUFFIX[@]}"; do spell_str "${T_SUFFIX[_i]}"; T_SUFFIX[_i]="$R"; done

# ---------- название компании ----------
pick T_SUFFIX; SUF="$R"
gen_surname; S1="$R"; gen_surname; S2="$R"
while [ "$S2" = "$S1" ]; do gen_surname; S2="$R"; done
chance 60
if [ "$R" -eq 1 ]; then pick WORDS; else gen_brand; fi
W1="$R"
pick PRE; P1="$R"; pick POST; P2="$R"
rnd 0 4
case "$R" in
    0) COMPANY="$S1 & $S2"
       chance 50
       if [ "$R" -eq 1 ] && [ "${SUF:0:1}" != "&" ]; then COMPANY="$COMPANY $SUF"; fi ;;
    1) COMPANY="$W1 $SUF" ;;
    2) COMPANY="$S1 $SUF" ;;
    3) COMPANY="${P1}${P2}"
       chance 70
       if [ "$R" -eq 1 ]; then COMPANY="$COMPANY $SUF"; fi ;;
    4) COMPANY="$W1"
       chance 80
       if [ "$R" -eq 1 ]; then COMPANY="$COMPANY $SUF"; fi ;;
esac
html_esc "$COMPANY"; COMPANY_H="$R"
INITIAL="${COMPANY:0:1}"

# ---------- прочие случайные значения ----------
rnd 2004 $((CUR_YEAR - 3)); YEAR="$R"
pick EMAIL_LOCALS; EMAIL="${R}@${DOMAIN}"
gen_hours
gen_address
if [ "$STREET_STYLE" = nl ]; then
    ADDR2="${POST} ${CITY}"
elif [ -n "$REGION" ]; then
    ADDR2="${CITY}, ${REGION} ${POST}"
else
    ADDR2="${CITY} ${POST}"
fi
REGION_JSON=""
if [ -n "$REGION" ]; then REGION_JSON="\"addressRegion\":\"${REGION}\","; fi

# ---------- тексты из шаблонов ----------
P_YEAR=("$YEAR"); P_CITY=("$CITY"); P_COUNTRYTHE=("$COUNTRY_THE")

gen HERO_TPL; HERO="$R"
HERO_HEAD="${HERO% *}"; HERO_LAST="${HERO##* }"
gen TAG_TPL;  TAGLINE="$R"
gen LEAD_TPL; LEAD="$R"

# услуги: «тема + форма» или самостоятельное название, описание по шаблону
gen_services() {
    local n="$1" i tries title t d used="|"
    SV=()
    for (( i=0; i<n; i++ )); do
        tries=0
        while :; do
            chance 28
            if [ "$R" -eq 1 ]; then
                pick P_SOLO; title="$R"; t="$R"
            else
                pick P_TOPIC; t="$R"; pick P_FORM; title="$t $R"
            fi
            tries=$(( tries + 1 ))
            case "$used" in
                *"|$title|"*|*"|t:$t|"*) if [ "$tries" -lt 15 ]; then continue; fi ;;
            esac
            break
        done
        used+="$title|t:$t|"
        spell_str "$title"; title="$R"
        pick_q SVCTPL; expand "$R"; d="${R^}"
        SV+=("$title|$d")
    done
}
rnd 0 2
case "$R" in 0) NSV=3 ;; 1) NSV=4 ;; 2) NSV=6 ;; esac
gen_services "$NSV"
SVC1="${SV[0]%%|*}"; SVC2="${SV[1]%%|*}"; SVC3="${SV[2]%%|*}"

# «о нас»
gen AS_ID; A1="$R"
pick AS_WORK; W_A="$R"; expand "$W_A"; A1+=" ${R^}"
gen AS_CL; A2="$R"
pick AS_WORK; while [ "$R" = "$W_A" ]; do pick AS_WORK; done
expand "$R"; A2+=" ${R^}"
T_ABOUT=("$A1" "$A2")
gen ABOUT_LOC_TPL; ABOUT3="$R"

# процесс из четырёх этапов
T_PROC=()
for _k in 1 2 3 4; do
    pick "P_ST$_k"; _nm="$R"
    gen "PT_S$_k"
    T_PROC+=("$_nm|$R")
done

# ценности
VU=("${VALUES[@]}"); shuffle VU
VS=()
for _u in "${VU[@]:0:3}"; do
    IFS='|' read -ra _vp <<< "$_u"
    _vt="${_vp[0]}"; _vp=("${_vp[@]:1}"); shuffle _vp
    VS+=("$_vt|We ${_vp[0]} and ${_vp[1]}.")
done

# отзывы (имена и организации добавляются при сборке секции)
T_QUOTES=()
for _qt in "${QT_TPL[@]}"; do expand "$_qt"; T_QUOTES+=("${R^}"); done

# заголовки и подписи
pick H_ABOUT; HT_ABOUT="$R"
pick H_SVC; HT_SVC="$R"
pick H_PROC; HT_PROC="$R"
pick H_QUOTES; HT_QUOTES="$R"
pick H_CONTACT; HT_CONTACT="$R"
gen SUBSVC_TPL;  ST_SVC="$R"
gen SUBPROC_TPL; ST_PROC="$R"
gen SUBQ_TPL;    ST_QUOTES="$R"
gen SUBC_TPL;    ST_CONTACT="$R"
pick CTA_NAV; BTN_NAV="$R"
pick CTA_HERO1; BTN_HERO1="$R"
pick CTA_HERO2; BTN_HERO2="$R"

case "${T_INDUSTRY:0:1}" in a|e|i|o|u) ARTICLE="an" ;; *) ARTICLE="a" ;; esac
EYEBROWS=("${CITY}, ${COUNTRY}" "${T_INDUSTRY^}" "Est. ${YEAR}" "Independent since ${YEAR}" "${T_INDUSTRY^} in ${CITY}")
pick EYEBROWS; EYEBROW="$R"

# ---------- метаданные ----------
rnd 0 4
case "$R" in
    0) TITLE="${COMPANY} | ${T_INDUSTRY^} in ${CITY}" ;;
    1) TITLE="${COMPANY} — ${SVC1}, ${SVC2}" ;;
    2) TITLE="${COMPANY} · ${T_INDUSTRY^}" ;;
    3) TITLE="${SVC1} in ${CITY} | ${COMPANY}" ;;
    4) TITLE="${COMPANY} — ${TAGLINE%.}" ;;
esac
rnd 0 2
case "$R" in
    0) META_DESC="${COMPANY} — ${T_INDUSTRY} in ${CITY}. ${TAGLINE}" ;;
    1) META_DESC="${COMPANY} is ${ARTICLE} ${T_INDUSTRY} based in ${CITY}. We offer ${SVC1,,}, ${SVC2,,} and ${SVC3,,}." ;;
    2) META_DESC="${TAGLINE} ${COMPANY} offers ${SVC1,,} and ${SVC2,,} for clients in ${CITY} and beyond." ;;
esac
html_esc "$TITLE"; TITLE_H="$R"
html_esc "$META_DESC"; META_DESC_H="$R"

KW_TAG=""
chance 40
if [ "$R" -eq 1 ]; then
    KW_TAG="<meta name=\"keywords\" content=\"${T_INDUSTRY}, ${SVC1,,}, ${SVC2,,}, ${SVC3,,}, ${CITY}\">"
fi
TW_TAG=""
chance 65
if [ "$R" -eq 1 ]; then TW_TAG="1"; fi

JSONLD="<script type=\"application/ld+json\">
{\"@context\":\"https://schema.org\",\"@type\":\"${T_SCHEMA}\",\"name\":\"${COMPANY}\",\"url\":\"https://${DOMAIN}/\",\"description\":\"${META_DESC}\",\"email\":\"${EMAIL}\",\"telephone\":\"${PHONE}\",\"foundingDate\":\"${YEAR}\",\"address\":{\"@type\":\"PostalAddress\",\"streetAddress\":\"${ADDR1}\",${REGION_JSON}\"addressLocality\":\"${CITY}\",\"postalCode\":\"${POST}\",\"addressCountry\":\"${ISO}\"}}
</script>"

# ============================================================
#  ДИЗАЙН
# ============================================================
LAYOUTS=(a b c d);           pick LAYOUTS;  LAYOUT="$R"
BGS=(grad mesh grid dots noise stripes solid anim); pick BGS; BG_KIND="$R"
CARDS=(flat outline shadow glass accent);           pick CARDS; CARD="$R"
SVCS=(grid list cols);       pick SVCS; SVC_STYLE="$R"

rnd 0 359; H="$R"
rnd 0 3
case "$R" in
    0) H2=$(( (H + 30) % 360 )) ;;
    1) H2=$(( (H + 150) % 360 )) ;;
    2) H2=$(( (H + 180) % 360 )) ;;
    3) H2=$(( (H + 210) % 360 )) ;;
esac
rnd 55 85; SAT="$R"
chance 55
if [ "$R" -eq 1 ]; then MODE=dark; else MODE=light; fi

if [ "$MODE" = dark ]; then
    rnd 8 14; BGL="$R"; rnd 18 40; BGS_="$R"; rnd 58 68; AL="$R"
    BG="hsl($H,${BGS_}%,${BGL}%)"; BG2="hsl($H,${BGS_}%,$((BGL + 6))%)"
    SURFACE="hsla(0,0%,100%,.05)"; GLASS="hsla(0,0%,100%,.07)"
    TEXT="hsl($H,15%,93%)"; MUTED="hsl($H,10%,70%)"
    ACCENT="hsl($H,${SAT}%,${AL}%)"; ACCENT2="hsl($H2,${SAT}%,${AL}%)"
    ON_ACC="hsl($H,40%,10%)"; ON_HEX="$(hsl2hex "$H" 40 10)"
    GLOW="hsla($H,${SAT}%,${AL}%,.22)"; GLOW2="hsla($H2,${SAT}%,${AL}%,.2)"
    BORDER="hsla(0,0%,100%,.1)"; BORDER_S="hsla(0,0%,100%,.22)"
    LINE="hsla(0,0%,100%,.045)"; LINE2="hsla(0,0%,100%,.12)"
    HDR="hsla($H,${BGS_}%,${BGL}%,.8)"
    SHADOW="0 10px 30px rgba(0,0,0,.35)"; SHADOW_C="rgba(0,0,0,.4)"
else
    rnd 95 98; BGL="$R"; rnd 20 45; BGS_="$R"; rnd 34 44; AL="$R"
    BG="hsl($H,${BGS_}%,${BGL}%)"; BG2="hsl($H,${BGS_}%,$((BGL - 5))%)"
    SURFACE="hsla(0,0%,100%,.85)"; GLASS="hsla(0,0%,100%,.6)"
    TEXT="hsl($H,30%,13%)"; MUTED="hsl($H,12%,38%)"
    ACCENT="hsl($H,${SAT}%,${AL}%)"; ACCENT2="hsl($H2,${SAT}%,${AL}%)"
    ON_ACC="#ffffff"; ON_HEX="#ffffff"
    GLOW="hsla($H,${SAT}%,${AL}%,.18)"; GLOW2="hsla($H2,${SAT}%,${AL}%,.16)"
    BORDER="hsla($H,30%,20%,.12)"; BORDER_S="hsla($H,30%,20%,.28)"
    LINE="hsla($H,30%,30%,.07)"; LINE2="hsla($H,30%,30%,.16)"
    HDR="hsla(0,0%,100%,.82)"
    SHADOW="0 10px 30px hsla($H,40%,20%,.12)"; SHADOW_C="hsla($H,40%,20%,.2)"
fi
THEME_HEX="$(hsl2hex "$H" "$BGS_" "$BGL")"
ACC_HEX="$(hsl2hex "$H" "$SAT" "$AL")"

RADII=(0px 4px 8px 12px 18px 24px);  pick RADII; RADIUS="$R"
BTN_RADII=(0px 6px 12px 999px);      pick BTN_RADII; BTN_RADIUS="$R"
MAXWS=(980 1040 1120 1200);          pick MAXWS; MAXW="$R"
SPACES=(72 88 104 120);              pick SPACES; SPACE="$R"
FSS=(16 17 18);                      pick FSS; FS="$R"
HWS=(400 500 600 700 800);           pick HWS; HW="$R"
HSPS=("-0.02em" "-0.01em" "0" "0.01em"); pick HSPS; HSP="$R"
chance 12
if [ "$R" -eq 1 ]; then HTR="uppercase"; HSP="0.06em"; else HTR="none"; fi

FONT_PAIRS=(
 "Georgia, 'Times New Roman', serif|-apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, Helvetica, Arial, sans-serif"
 "'Palatino Linotype', Palatino, 'Book Antiqua', Georgia, serif|Georgia, 'Times New Roman', serif"
 "'Trebuchet MS', 'Lucida Grande', 'Segoe UI', sans-serif|'Segoe UI', Tahoma, Geneva, Verdana, sans-serif"
 "'Helvetica Neue', Helvetica, Arial, sans-serif|'Helvetica Neue', Helvetica, Arial, sans-serif"
 "Verdana, Geneva, sans-serif|Verdana, Geneva, sans-serif"
 "'Courier New', Courier, monospace|-apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, Arial, sans-serif"
 "'Gill Sans', 'Gill Sans MT', Calibri, 'Trebuchet MS', sans-serif|'Gill Sans', 'Gill Sans MT', Calibri, sans-serif"
 "ui-serif, Georgia, Cambria, serif|ui-sans-serif, system-ui, -apple-system, 'Segoe UI', Roboto, sans-serif"
)
while :; do
    pick FONT_PAIRS; FP="$R"
    case "$FP" in
        "'Courier New'"*) if [ "$T_KEY" != software ]; then continue; fi ;;
    esac
    break
done
FONT_H="${FP%%|*}"; FONT_B="${FP##*|}"

FX=""
chance 55; if [ "$R" -eq 1 ]; then FX+=" fx-lift"; fi
chance 50; if [ "$R" -eq 1 ]; then FX+=" fx-grad"; fi
chance 45; if [ "$R" -eq 1 ]; then FX+=" fx-glow"; fi
chance 60; if [ "$R" -eq 1 ]; then REV=" reveal"; else REV=""; fi
BODY_CLASS="l-${LAYOUT} bg-${BG_KIND} card-${CARD} svc-${SVC_STYLE}${FX}"

# ---------- логотип / favicon ----------
rnd 0 4; MARK_SHAPE="$R"
mark_svg() {    # $1 = заливка фигуры, $2 = цвет буквы  ->  MARK_INNER
    local shape
    case "$MARK_SHAPE" in
        0) shape="<circle cx=\"16\" cy=\"16\" r=\"16\" fill=\"$1\"/>" ;;
        1) shape="<rect width=\"32\" height=\"32\" rx=\"7\" fill=\"$1\"/>" ;;
        2) shape="<path d=\"M16 0 32 16 16 32 0 16Z\" fill=\"$1\"/>" ;;
        3) shape="<rect width=\"32\" height=\"32\" fill=\"$1\"/>" ;;
        4) shape="<path d=\"M8 2h16l8 14-8 14H8L0 16z\" fill=\"$1\"/>" ;;
    esac
    MARK_INNER="${shape}<text x=\"16\" y=\"21.5\" text-anchor=\"middle\" font-family=\"Georgia, serif\" font-size=\"16\" font-weight=\"700\" fill=\"$2\">${INITIAL}</text>"
}
mark_svg "var(--accent)" "var(--on-accent)"
MARK_HTML="<svg class=\"mark\" viewBox=\"0 0 32 32\" aria-hidden=\"true\">${MARK_INNER}</svg>"
mark_svg "$ACC_HEX" "$ON_HEX"
FAVICON_SVG="<svg xmlns=\"http://www.w3.org/2000/svg\" viewBox=\"0 0 32 32\">${MARK_INNER}</svg>"

# ---------- абстрактная иллюстрация для hero (layout b) ----------
make_art() {
    local n i t cx cy r op rot col x2 y2 o
    ART="<svg viewBox=\"0 0 400 400\" xmlns=\"http://www.w3.org/2000/svg\" role=\"presentation\">"
    rnd 6 9; n="$R"
    for (( i=0; i<n; i++ )); do
        rnd 0 3; t="$R"
        rnd 40 360; cx="$R"; rnd 40 360; cy="$R"; rnd 24 90; r="$R"; rnd 12 70; op="$R"
        if (( RANDOM % 2 )); then col="var(--accent)"; else col="var(--accent2)"; fi
        printf -v o '%02d' "$op"
        case "$t" in
            0) ART+="<circle cx=\"$cx\" cy=\"$cy\" r=\"$r\" fill=\"$col\" opacity=\"0.$o\"/>" ;;
            1) rnd 0 90; rot="$R"
               ART+="<rect x=\"$((cx - r))\" y=\"$((cy - r))\" width=\"$((r * 2))\" height=\"$((r * 2))\" rx=\"$((r / 4))\" fill=\"$col\" opacity=\"0.$o\" transform=\"rotate($rot $cx $cy)\"/>" ;;
            2) printf -v o '%02d' "$((op + 25))"
               ART+="<circle cx=\"$cx\" cy=\"$cy\" r=\"$r\" fill=\"none\" stroke=\"$col\" stroke-width=\"3\" opacity=\"0.$o\"/>" ;;
            3) x2=$(( cx - 120 + RANDOM % 241 )); y2=$(( cy - 120 + RANDOM % 241 ))
               printf -v o '%02d' "$((op + 25))"
               ART+="<line x1=\"$cx\" y1=\"$cy\" x2=\"$x2\" y2=\"$y2\" stroke=\"$col\" stroke-width=\"4\" stroke-linecap=\"round\" opacity=\"0.$o\"/>" ;;
        esac
    done
    ART+="</svg>"
}
HERO_ART_HTML=""
if [ "$LAYOUT" = "b" ]; then
    make_art
    HERO_ART_HTML="<div class=\"hero-art\" aria-hidden=\"true\">${ART}</div>"
fi

# ---------- порядок секций и навигация ----------
MID=(process quotes stats); shuffle MID
chance 50
if [ "$R" -eq 1 ]; then ORDER=(about services); else ORDER=(services about); fi
for s in "${MID[@]}"; do
    chance 65
    if [ "$R" -eq 1 ]; then ORDER+=("$s"); fi
done
if [ "${#ORDER[@]}" -eq 2 ]; then ORDER+=("${MID[0]}"); fi
ORDER+=(contact)

NAV_HTML=""
for s in "${ORDER[@]}"; do
    case "$s" in
        about)    NAV_HTML+="<a href=\"/#about\">About</a>"$'\n' ;;
        services) NAV_HTML+="<a href=\"/#services\">Services</a>"$'\n' ;;
        process)  NAV_HTML+="<a href=\"/#process\">Process</a>"$'\n' ;;
        quotes)   NAV_HTML+="<a href=\"/#clients\">Clients</a>"$'\n' ;;
        contact)  NAV_HTML+="<a href=\"/#contact\">Contact</a>"$'\n' ;;
    esac
done
NAV_HTML+="<a class=\"btn btn-sm\" href=\"/#contact\">${BTN_NAV}</a>"

# ---------- даты ----------
rnd 10 60; LASTMOD_AGO="$R"
LASTMOD="$(date -d "${LASTMOD_AGO} days ago" +%Y-%m-%d)"
case "$DATE_STYLE" in
    mdy) UPD_DATE="$(date -d "${LASTMOD_AGO} days ago" +"%B %-d, %Y")" ;;
    *)     UPD_DATE="$(date -d "${LASTMOD_AGO} days ago" +"%-d %B %Y")" ;;
esac
rnd 0 1
if [ "$R" -eq 0 ]; then FOOT_YEARS="${YEAR}–${CUR_YEAR}"; else FOOT_YEARS="${CUR_YEAR}"; fi
chance 40; if [ "$R" -eq 1 ]; then FOOT_EXTRA=" Registered in ${COUNTRY_THE}."; else FOOT_EXTRA=""; fi

# ---------- имена файлов ----------
ASSET_DIRS=(assets static res); pick ASSET_DIRS; ASSETS="$R"
CSS_NAMES=(style.css main.css site.css); pick CSS_NAMES; CSS_NAME="$R"
JS_NAMES=(main.js site.js app.js); pick JS_NAMES; JS_NAME="$R"

# ============================================================
#  ФУНКЦИИ РАЗМЕТКИ
# ============================================================
emit_head() {   # $1 title  $2 description  $3 path  $4 robots  $5 extra-head
    local og_tw=""
    if [ -n "$TW_TAG" ]; then
        og_tw="<meta name=\"twitter:card\" content=\"summary\">
<meta name=\"twitter:title\" content=\"$1\">
<meta name=\"twitter:description\" content=\"$2\">"
    fi
    local kw=""
    if [ "$3" = "/" ]; then kw="$KW_TAG"; fi
    cat <<HEAD
<!DOCTYPE html>
<html lang="${LANG_CODE}">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>$1</title>
<meta name="description" content="$2">
${kw}
<meta name="robots" content="$4">
<meta name="theme-color" content="${THEME_HEX}">
<link rel="canonical" href="https://${DOMAIN}$3">
<meta property="og:type" content="website">
<meta property="og:site_name" content="${COMPANY_H}">
<meta property="og:title" content="$1">
<meta property="og:description" content="$2">
<meta property="og:url" content="https://${DOMAIN}$3">
<meta property="og:locale" content="${OG_LOCALE}">
${og_tw}
<link rel="icon" type="image/svg+xml" href="/favicon.svg">
<link rel="stylesheet" href="/${ASSETS}/${CSS_NAME}">
<script src="/${ASSETS}/${JS_NAME}"></script>
$5
</head>
HEAD
}

emit_header() {
    cat <<HDR
<body class="${BODY_CLASS}">
<a class="skip" href="#main">Skip to content</a>
<header class="site-header">
<div class="wrap bar">
<a class="brand" href="/">${MARK_HTML}<span>${COMPANY_H}</span></a>
<button class="nav-toggle" type="button" aria-label="Menu" aria-expanded="false"><span></span></button>
<nav class="nav" aria-label="Main">
${NAV_HTML}
</nav>
</div>
</header>
<main id="main">
HDR
}

emit_footer() {
    cat <<FTR
</main>
<footer class="site-footer">
<div class="wrap foot">
<span>&copy; ${FOOT_YEARS} ${COMPANY_H} ${LEGAL}${LEGAL_DOT} All rights reserved.${FOOT_EXTRA}</span>
<span><a href="/privacy.html">Privacy policy</a></span>
</div>
</footer>
</body>
</html>
FTR
}

sec_hero() {
    cat <<SEC
<section class="hero">
<div class="wrap hero-grid">
<div class="hero-copy">
<span class="eyebrow">${EYEBROW}</span>
<h1>${HERO_HEAD} <span class="g">${HERO_LAST}</span></h1>
<p class="lead">${LEAD}</p>
<div class="actions">
<a class="btn" href="/#contact">${BTN_HERO1}</a>
<a class="btn btn-ghost" href="/#services">${BTN_HERO2}</a>
</div>
</div>
${HERO_ART_HTML}
</div>
</section>
SEC
}

sec_about() {
    local v li=""
    for v in "${VS[@]}"; do
        li+="<li><strong>${v%%|*}</strong><span>${v##*|}</span></li>"$'\n'
    done
    cat <<SEC
<section id="about" class="section${REV}">
<div class="wrap">
<div class="section-head"><h2>${HT_ABOUT}</h2></div>
<div class="about-grid">
<div class="about-text">
<p>${T_ABOUT[0]}</p>
<p>${T_ABOUT[1]}</p>
<p>${ABOUT3}</p>
</div>
<ul class="values">
${li}</ul>
</div>
</div>
</section>
SEC
}

sec_services() {
    local i=0 s cards=""
    for s in "${SV[@]}"; do
        i=$((i + 1))
        cards+="<article class=\"card\"><span class=\"num\">$(printf '%02d' "$i")</span><h3>${s%%|*}</h3><p>${s##*|}</p></article>"$'\n'
    done
    cat <<SEC
<section id="services" class="section${REV}">
<div class="wrap">
<div class="section-head"><h2>${HT_SVC}</h2><p class="sub">${ST_SVC}</p></div>
<div class="cards">
${cards}</div>
</div>
</section>
SEC
}

sec_stats() {
    local a b lab1 min1 max1 lab2 min2 max2 n1 n2 plus="" yl
    IFS='|' read -r lab1 min1 max1 <<< "${T_STATS[0]}"
    IFS='|' read -r lab2 min2 max2 <<< "${T_STATS[1]}"
    rnd "$min1" "$max1"; n1="$R"
    rnd "$min2" "$max2"; n2="$R"
    chance 60; if [ "$R" -eq 1 ]; then plus="+"; fi
    rnd 0 1; if [ "$R" -eq 0 ]; then yl="Years in business"; else yl="Years of experience"; fi
    cat <<SEC
<section class="section band${REV}">
<div class="wrap">
<div class="stats">
<div class="stat"><b>$((CUR_YEAR - YEAR))${plus}</b><span>${yl}</span></div>
<div class="stat"><b>${n1}${plus}</b><span>${lab1}</span></div>
<div class="stat"><b>${n2}${plus}</b><span>${lab2}</span></div>
</div>
</div>
</section>
SEC
}

sec_process() {
    local p items=""
    for p in "${T_PROC[@]}"; do
        items+="<li class=\"step\"><h3>${p%%|*}</h3><p>${p##*|}</p></li>"$'\n'
    done
    cat <<SEC
<section id="process" class="section${REV}">
<div class="wrap">
<div class="section-head"><h2>${HT_PROC}</h2><p class="sub">${ST_PROC}</p></div>
<ol class="steps">
${items}</ol>
</div>
</section>
SEC
}

sec_quotes() {
    local QS=("${T_QUOTES[@]}") q out="" f l o r n
    shuffle QS
    n=3; chance 40; if [ "$R" -eq 1 ]; then n=2; fi
    QS=("${QS[@]:0:n}")
    for q in "${QS[@]}"; do
        pick FIRST; f="$R"; gen_surname; l="$R"; gen_org; o="$R"; pick ROLES; r="$R"
        out+="<blockquote><p>${q}</p><cite><b>${f} ${l}</b>, ${r}, ${o}</cite></blockquote>"$'\n'
    done
    cat <<SEC
<section id="clients" class="section${REV}">
<div class="wrap">
<div class="section-head"><h2>${HT_QUOTES}</h2><p class="sub">${ST_QUOTES}</p></div>
<div class="quotes">
${out}</div>
</div>
</section>
SEC
}

sec_contact() {
    cat <<SEC
<section id="contact" class="section${REV}">
<div class="wrap">
<div class="section-head"><h2>${HT_CONTACT}</h2><p class="sub">${ST_CONTACT}</p></div>
<div class="contact-grid">
<div><h3>Visit</h3><p>${ADDR1}<br>${ADDR2}<br>${COUNTRY}</p></div>
<div><h3>Call</h3><p><a href="tel:${PHONE// /}">${PHONE}</a></p></div>
<div><h3>Write</h3><p><a href="mailto:${EMAIL}">${EMAIL}</a></p></div>
<div><h3>Hours</h3><p>${OPEN_HOURS}</p></div>
</div>
</div>
</section>
SEC
}

# ============================================================
#  ЗАПИСЬ ФАЙЛОВ
# ============================================================
# Не очищаем WEBROOT целиком: существующие пользовательские файлы сохраняются.
mkdir -p "${WEBROOT}/${ASSETS}"

# ---------- index.html ----------
{
    emit_head "$TITLE_H" "$META_DESC_H" "/" "index, follow, max-image-preview:large" "$JSONLD"
    emit_header
    sec_hero
    for s in "${ORDER[@]}"; do "sec_$s"; done
    emit_footer
} > "${WEBROOT}/index.html"

# ---------- privacy.html ----------
{
    emit_head "Privacy policy | ${COMPANY_H}" "How ${COMPANY_H} handles personal information collected through this website." "/privacy.html" "index, follow" ""
    emit_header
    cat <<PRIV
<article class="prose">
<h1>Privacy policy</h1>
<p>Last updated: ${UPD_DATE}</p>
<h2>Who we are</h2>
<p>${COMPANY_H} ${LEGAL} (&ldquo;we&rdquo;, &ldquo;us&rdquo;) is based in ${CITY}, ${COUNTRY}. This policy explains how we handle personal information when you visit this website or contact us.</p>
<h2>Information we collect</h2>
<p>If you contact us by email or telephone, we keep the details you provide, such as your name, contact information and the content of your message, so that we can respond. Our web server also records standard technical information, including IP address, browser type and the pages requested, for security and troubleshooting.</p>
<h2>How we use it</h2>
<p>We use this information to answer questions, provide our services, keep this site secure and meet legal obligations. We do not sell personal information and we do not use it for automated decision-making.</p>
<h2>Cookies</h2>
<p>This website does not use advertising or tracking cookies. Any cookies that are set are strictly necessary for the site to work.</p>
<h2>Retention</h2>
<p>Server logs are kept for up to ninety days. Correspondence is kept for as long as it is needed to deal with your request and any follow-up, and for the period required by law.</p>
<h2>Your rights</h2>
<p>Depending on where you live, you may have the right to access, correct or delete the personal information we hold about you, or to object to how we use it. To exercise these rights, please contact us using the details below.</p>
<h2>Contact</h2>
<p>Email <a href="mailto:${EMAIL}">${EMAIL}</a> or write to us at ${ADDR1}, ${ADDR2}, ${COUNTRY}.</p>
</article>
PRIV
    emit_footer
} > "${WEBROOT}/privacy.html"

# ---------- 404.html ----------
{
    emit_head "Page not found | ${COMPANY_H}" "The page you are looking for could not be found." "/404.html" "noindex" ""
    emit_header
    cat <<ERR
<section class="err">
<p class="code">404</p>
<h1>Page not found</h1>
<p class="sub">The page you are looking for may have been moved or no longer exists.</p>
<p><a class="btn" href="/">Back to the home page</a></p>
</section>
ERR
    emit_footer
} > "${WEBROOT}/404.html"

# ---------- favicon ----------
echo "$FAVICON_SVG" > "${WEBROOT}/favicon.svg"

# ---------- robots.txt / sitemap.xml ----------
chance 50
if [ "$R" -eq 1 ]; then ROBOTS_RULE="Allow: /"; else ROBOTS_RULE="Disallow:"; fi
cat > "${WEBROOT}/robots.txt" <<ROBOTS
User-agent: *
${ROBOTS_RULE}

Sitemap: https://${DOMAIN}/sitemap.xml
ROBOTS

CHANGEFREQS=(monthly yearly); pick CHANGEFREQS; CF="$R"
cat > "${WEBROOT}/sitemap.xml" <<SITEMAP
<?xml version="1.0" encoding="UTF-8"?>
<urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9">
  <url>
    <loc>https://${DOMAIN}/</loc>
    <lastmod>${LASTMOD}</lastmod>
    <changefreq>${CF}</changefreq>
    <priority>1.0</priority>
  </url>
  <url>
    <loc>https://${DOMAIN}/privacy.html</loc>
    <lastmod>${LASTMOD}</lastmod>
    <changefreq>yearly</changefreq>
    <priority>0.3</priority>
  </url>
</urlset>
SITEMAP

# ---------- CSS ----------
{
cat <<ROOT
/* ${COMPANY_H} — main stylesheet */
:root{
color-scheme:${MODE};
--bg:${BG};--bg2:${BG2};--surface:${SURFACE};--glass:${GLASS};--text:${TEXT};--muted:${MUTED};
--accent:${ACCENT};--accent2:${ACCENT2};--on-accent:${ON_ACC};--glow:${GLOW};--glow2:${GLOW2};
--border:${BORDER};--border-strong:${BORDER_S};--line:${LINE};--line2:${LINE2};--hdr:${HDR};
--shadow:${SHADOW};--shadow-c:${SHADOW_C};
--radius:${RADIUS};--btn-radius:${BTN_RADIUS};--maxw:${MAXW}px;--space:${SPACE}px;--fs:${FS}px;
--font-h:${FONT_H};--font-b:${FONT_B};
--h-weight:${HW};--h-spacing:${HSP};--h-transform:${HTR};
}
ROOT
cat <<'CSS'
*,*::before,*::after{box-sizing:border-box}
html{scroll-behavior:smooth;scroll-padding-top:84px;-webkit-text-size-adjust:100%}
body{margin:0;font-family:var(--font-b);font-size:var(--fs);line-height:1.65;color:var(--text);background:var(--bg);min-height:100vh;position:relative;overflow-x:hidden}
img,svg{max-width:100%}
a{color:var(--accent);text-decoration:none}
a:hover{text-decoration:underline}
h1,h2,h3{font-family:var(--font-h);font-weight:var(--h-weight);letter-spacing:var(--h-spacing);line-height:1.15;margin:0 0 .5em}
h2,h3{text-transform:var(--h-transform)}
h1{font-size:clamp(2.2rem,5vw,3.8rem)}
h2{font-size:clamp(1.6rem,3vw,2.2rem)}
h3{font-size:1.15rem}
p{margin:0 0 1em}
.wrap{width:100%;max-width:var(--maxw);margin:0 auto;padding:0 24px}
.skip{position:absolute;left:-999px;top:0}
.skip:focus{left:12px;top:12px;background:var(--accent);color:var(--on-accent);padding:8px 12px;z-index:100}

/* background layer */
body::before{content:"";position:fixed;inset:0;z-index:-1;pointer-events:none}
.bg-grad::before{background:linear-gradient(135deg,var(--bg),var(--bg2))}
.bg-mesh::before{background:radial-gradient(circle at 15% 10%,var(--glow),transparent 45%),radial-gradient(circle at 85% 30%,var(--glow2),transparent 40%),radial-gradient(circle at 40% 95%,var(--glow),transparent 45%),var(--bg)}
.bg-grid::before{background-color:var(--bg);background-image:linear-gradient(var(--line) 1px,transparent 1px),linear-gradient(90deg,var(--line) 1px,transparent 1px);background-size:44px 44px}
.bg-dots::before{background-color:var(--bg);background-image:radial-gradient(var(--line2) 1.2px,transparent 1.2px);background-size:22px 22px}
.bg-noise::before{background-color:var(--bg);background-image:url("data:image/svg+xml,%3Csvg xmlns='http://www.w3.org/2000/svg' width='160' height='160'%3E%3Cfilter id='n'%3E%3CfeTurbulence type='fractalNoise' baseFrequency='.8' numOctaves='2' stitchTiles='stitch'/%3E%3C/filter%3E%3Crect width='100%25' height='100%25' filter='url(%23n)' opacity='.07'/%3E%3C/svg%3E")}
.bg-stripes::before{background:repeating-linear-gradient(135deg,transparent 0 22px,var(--line) 22px 23px),linear-gradient(var(--bg),var(--bg2))}
.bg-solid::before{background:var(--bg)}
.bg-anim::before{background:linear-gradient(120deg,var(--bg),var(--bg2),var(--glow),var(--bg));background-size:300% 300%;animation:drift 24s ease infinite}
@keyframes drift{0%{background-position:0 50%}50%{background-position:100% 50%}100%{background-position:0 50%}}

/* header */
.site-header{position:sticky;top:0;z-index:20;background:var(--hdr);-webkit-backdrop-filter:blur(10px);backdrop-filter:blur(10px);border-bottom:1px solid var(--border)}
.bar{display:flex;align-items:center;justify-content:space-between;gap:20px;min-height:68px}
.brand{display:flex;align-items:center;gap:10px;color:var(--text);font-family:var(--font-h);font-weight:700;font-size:1.15rem}
.brand:hover{text-decoration:none}
.mark{width:32px;height:32px;flex:none}
.nav{display:flex;align-items:center;gap:26px}
.nav a{color:var(--text);font-size:.95rem;opacity:.85}
.nav a:hover{opacity:1;text-decoration:none;color:var(--accent)}
.nav .btn{opacity:1;color:var(--on-accent)}
.nav .btn:hover{color:var(--on-accent)}
.nav-toggle{display:none;background:none;border:1px solid var(--border);border-radius:8px;width:42px;height:38px;cursor:pointer;color:var(--text)}
.nav-toggle span,.nav-toggle span::before,.nav-toggle span::after{display:block;width:18px;height:2px;background:currentColor;margin:0 auto;position:relative;content:""}
.nav-toggle span::before{position:absolute;top:-6px;left:0}
.nav-toggle span::after{position:absolute;top:6px;left:0}

/* buttons */
.btn{display:inline-block;padding:.75em 1.5em;border-radius:var(--btn-radius);background:var(--accent);color:var(--on-accent);font-weight:600;font-size:.95rem;border:2px solid var(--accent);transition:transform .2s,box-shadow .2s,border-color .2s,color .2s}
.btn:hover{text-decoration:none;transform:translateY(-2px);box-shadow:0 8px 20px var(--glow)}
.btn-ghost{background:transparent;color:var(--text);border-color:var(--border-strong)}
.btn-ghost:hover{border-color:var(--accent);color:var(--accent);box-shadow:none}
.btn-sm{padding:.5em 1.1em;font-size:.88rem}

/* hero */
.hero{padding:calc(var(--space) * 1.1) 0 var(--space);position:relative}
.hero-grid{display:grid;gap:48px;align-items:center}
.eyebrow{display:inline-block;font-size:.8rem;letter-spacing:.14em;text-transform:uppercase;color:var(--accent);margin-bottom:18px;font-weight:600}
.lead{font-size:1.2rem;color:var(--muted);max-width:620px}
.actions{display:flex;flex-wrap:wrap;gap:14px;margin-top:28px}
.hero-art{display:none}
.hero-art svg{width:100%;height:auto;max-width:420px;margin:0 auto;display:block}
.fx-grad h1 .g{background:linear-gradient(90deg,var(--accent),var(--accent2));-webkit-background-clip:text;background-clip:text;color:transparent}
.fx-glow .hero::before{content:"";position:absolute;width:420px;height:420px;border-radius:50%;background:var(--glow);filter:blur(90px);top:-60px;right:8%;z-index:-1;animation:float 14s ease-in-out infinite}
@keyframes float{50%{transform:translate(-40px,50px)}}

/* layout variants */
.l-a .hero{text-align:center}
.l-a .lead{margin-left:auto;margin-right:auto}
.l-a .actions{justify-content:center}
.l-a .section-head{margin-left:auto;margin-right:auto;text-align:center}
.l-b .hero-grid{grid-template-columns:1.2fr .8fr}
.l-b .hero-art{display:block}
.l-c .bar{flex-direction:column;padding-top:18px;padding-bottom:12px;gap:12px}
.l-c .brand{font-size:1.5rem}
.l-c .hero h1{font-size:clamp(2.4rem,6vw,4.6rem);border-top:3px solid var(--accent);padding-top:24px}
.l-d h1{font-size:clamp(2rem,4vw,3.2rem)}
@media(min-width:900px){
.l-d{display:grid;grid-template-columns:270px minmax(0,1fr);grid-template-rows:1fr auto}
.l-d .site-header{grid-column:1;grid-row:1/3;position:sticky;top:0;height:100vh;align-self:start;border-bottom:0;border-right:1px solid var(--border)}
.l-d .bar{flex-direction:column;align-items:flex-start;justify-content:flex-start;padding-top:36px;gap:40px;min-height:0}
.l-d .nav{flex-direction:column;align-items:flex-start;gap:14px}
.l-d main{grid-column:2;grid-row:1}
.l-d .site-footer{grid-column:2;grid-row:2}
}

/* sections */
.section{padding:var(--space) 0}
.section-head{max-width:640px;margin-bottom:40px}
.sub{color:var(--muted)}
.about-grid{display:grid;gap:48px;grid-template-columns:1.4fr 1fr}
.about-text p{color:var(--muted)}
.values{list-style:none;margin:0;padding:0;display:grid;gap:18px;align-content:start}
.values li{padding-left:18px;border-left:2px solid var(--accent)}
.values strong{display:block;font-family:var(--font-h)}
.values span{color:var(--muted);font-size:.95rem}
.band{background:var(--surface);border-top:1px solid var(--border);border-bottom:1px solid var(--border);padding:calc(var(--space) * .6) 0}

/* cards */
.cards{display:grid;gap:22px;grid-template-columns:repeat(auto-fit,minmax(250px,1fr))}
.card{padding:28px;border-radius:var(--radius);background:var(--surface);border:1px solid var(--border);transition:transform .25s,box-shadow .25s,border-color .25s}
.card h3{margin-bottom:.4em}
.card p{margin:0;color:var(--muted);font-size:.97rem}
.num{display:block;font-family:var(--font-h);color:var(--accent);font-size:.85rem;letter-spacing:.1em;margin-bottom:14px}
.card-flat .card{border-color:transparent}
.card-outline .card{background:transparent;border-color:var(--border-strong)}
.card-shadow .card{border-color:transparent;box-shadow:var(--shadow)}
.card-glass .card{background:var(--glass);-webkit-backdrop-filter:blur(12px);backdrop-filter:blur(12px)}
.card-accent .card{border:0;border-left:4px solid var(--accent);border-radius:calc(var(--radius) / 2)}
.fx-lift .card:hover{transform:translateY(-6px);box-shadow:0 16px 36px var(--shadow-c)}
.svc-list .cards{grid-template-columns:1fr;gap:14px}
.svc-list .card{display:grid;grid-template-columns:60px 1fr 1.5fr;gap:20px;align-items:baseline}
.svc-list .card h3,.svc-list .card p,.svc-list .num{margin:0}
.svc-cols .cards{grid-template-columns:repeat(2,1fr)}

/* stats / steps / quotes / contact */
.stats{display:grid;gap:24px;grid-template-columns:repeat(auto-fit,minmax(170px,1fr));text-align:center}
.stat b{display:block;font-family:var(--font-h);font-size:clamp(2rem,4vw,3rem);color:var(--accent);line-height:1.1}
.stat span{color:var(--muted);font-size:.92rem}
.steps{list-style:none;margin:0;padding:0;display:grid;gap:28px;grid-template-columns:repeat(auto-fit,minmax(210px,1fr));counter-reset:s}
.step{position:relative;padding-top:52px;counter-increment:s}
.step::before{content:counter(s,decimal-leading-zero);position:absolute;top:0;left:0;font-family:var(--font-h);font-size:1.6rem;color:var(--accent);line-height:1}
.step::after{content:"";position:absolute;top:14px;left:52px;right:0;height:1px;background:var(--border-strong)}
.step p{color:var(--muted);font-size:.97rem}
.quotes{display:grid;gap:22px;grid-template-columns:repeat(auto-fit,minmax(280px,1fr))}
blockquote{margin:0;padding:28px;border-radius:var(--radius);background:var(--surface);border:1px solid var(--border)}
blockquote p{font-size:1.02rem;font-style:italic}
blockquote p::before{content:"\201C"}
blockquote p::after{content:"\201D"}
cite{display:block;font-style:normal;font-size:.9rem;color:var(--muted)}
cite b{color:var(--text)}
.contact-grid{display:grid;gap:26px;grid-template-columns:repeat(auto-fit,minmax(200px,1fr))}
.contact-grid h3{font-size:.8rem;text-transform:uppercase;letter-spacing:.12em;color:var(--accent);margin-bottom:.5em}
.contact-grid p{margin:0}

/* footer, text pages */
.site-footer{border-top:1px solid var(--border);padding:34px 0;color:var(--muted);font-size:.9rem}
.foot{display:flex;flex-wrap:wrap;gap:12px 28px;justify-content:space-between}
.foot a{color:var(--muted)}
.foot a:hover{color:var(--accent)}
.prose{max-width:760px;margin:0 auto;padding:64px 24px}
.prose h1{font-size:2.2rem}
.prose h2{font-size:1.2rem;margin-top:1.8em}
.prose p{color:var(--muted)}
.err{text-align:center;padding:110px 24px}
.err .code{font-family:var(--font-h);font-size:clamp(5rem,16vw,9rem);color:var(--accent);line-height:1;margin:0}

/* reveal */
.js .reveal{opacity:0;transform:translateY(22px);transition:opacity .7s ease,transform .7s ease}
.js .reveal.in{opacity:1;transform:none}
@media(prefers-reduced-motion:reduce){*{animation:none!important;transition:none!important}.js .reveal{opacity:1;transform:none}}

/* mobile */
@media(max-width:899px){
.nav-toggle{display:block}
.nav{display:none;position:absolute;top:100%;left:0;right:0;flex-direction:column;align-items:flex-start;gap:14px;padding:20px 24px;background:var(--bg);border-bottom:1px solid var(--border)}
.nav.open{display:flex}
.l-b .hero-grid,.about-grid{grid-template-columns:1fr}
.l-c .bar{flex-direction:row;padding-top:0;padding-bottom:0}
.l-c .brand{font-size:1.15rem}
.svc-list .card{grid-template-columns:1fr;gap:6px}
.svc-cols .cards{grid-template-columns:1fr}
.hero{padding-top:var(--space)}
}
CSS
} > "${WEBROOT}/${ASSETS}/${CSS_NAME}"

# ---------- JS ----------
cat > "${WEBROOT}/${ASSETS}/${JS_NAME}" <<'JS'
(function () {
  var d = document;
  d.documentElement.classList.add('js');
  d.addEventListener('DOMContentLoaded', function () {
    var t = d.querySelector('.nav-toggle'), n = d.querySelector('.nav');
    if (t && n) {
      t.addEventListener('click', function () {
        var o = n.classList.toggle('open');
        t.setAttribute('aria-expanded', o ? 'true' : 'false');
      });
      n.addEventListener('click', function (e) {
        if (e.target.tagName === 'A') {
          n.classList.remove('open');
          t.setAttribute('aria-expanded', 'false');
        }
      });
    }
    var els = d.querySelectorAll('.reveal');
    if ('IntersectionObserver' in window) {
      var io = new IntersectionObserver(function (es) {
        es.forEach(function (e) {
          if (e.isIntersecting) { e.target.classList.add('in'); io.unobserve(e.target); }
        });
      }, { threshold: 0.12 });
      els.forEach(function (el) { io.observe(el); });
    } else {
      els.forEach(function (el) { el.classList.add('in'); });
    }
  });
})();
JS

# ---------- «возраст» файлов: правдоподобные даты изменения ----------
# Не меняем timestamps и права уже существовавших файлов в каталоге сайта.
# Новые файлы создаются с системной umask пользователя root.

echo "  -> Сид:        ${SEED}   (повтор: HONEYPOT_SEED=${SEED} ./honeypot-generator.sh ${DOMAIN})"
echo "  -> Компания:   ${COMPANY} (${T_INDUSTRY}, ${CITY})"
echo "  -> Дизайн:     layout=${LAYOUT}, фон=${BG_KIND}, карточки=${CARD}, услуги=${SVC_STYLE}, тема=${MODE}, hue=${H}${FX}"
echo "  -> Файлы:      ${WEBROOT} (index, privacy, 404, robots, sitemap, favicon, ${ASSETS}/)"

if [ "$DRY_RUN" = "1" ]; then
    paint "$C_GREEN" "✓ Генерация завершена. Режим dry-run: nginx и сертификат не затрагивались."
    exit 0
fi

# ------------------------------------------------------------
# nginx: сначала HTTP-конфиг для получения сертификата
# ------------------------------------------------------------
step "4/6  Настройка nginx (HTTP для ACME)"

cat > "${NGINX_AVAILABLE}/${DOMAIN}.conf" <<NGINXHTTP
server {
    listen 80;
    listen [::]:80;
    server_name ${DOMAIN};

    root ${WEBROOT};
    index index.html;

    location /.well-known/acme-challenge/ {
        root /var/www/certbot;
    }

    location / {
        try_files \$uri \$uri/ =404;
    }
}
NGINXHTTP

ln -sf "${NGINX_AVAILABLE}/${DOMAIN}.conf" "${NGINX_ENABLED}/${DOMAIN}.conf"

if ! nginx -t; then
    paint "$C_RED" "✖ Проверка nginx не прошла. Перезагрузка не выполнялась."
    exit 1
fi
if ! systemctl reload nginx; then
    paint "$C_RED" "✖ Не удалось перезагрузить nginx. Проверьте systemctl status nginx."
    exit 1
fi
echo "  ✓ HTTP-конфиг применён; конфиги других сайтов не переписывались."

# ------------------------------------------------------------
# Получение сертификата Let's Encrypt
# ------------------------------------------------------------
step "5/6  Получение сертификата Let's Encrypt"

CERT_EMAIL="admin@${DOMAIN}"
if ! certbot certonly --webroot -w /var/www/certbot \
    -d "${DOMAIN}" \
    --non-interactive --agree-tos -m "${CERT_EMAIL}"; then
    exit 1
fi

if [ ! -f "/etc/letsencrypt/live/${DOMAIN}/fullchain.pem" ]; then
    exit 1
fi

echo "  -> Сертификат получен: /etc/letsencrypt/live/${DOMAIN}/"

# ------------------------------------------------------------
# Обновление nginx-конфига под HTTPS
# (синтаксис http2 зависит от версии nginx)
# ------------------------------------------------------------
step "6/6  Включение HTTPS и автообновления сертификата"

NGINX_VER="$(nginx -v 2>&1 | sed 's/.*nginx\///; s/[^0-9.].*//')"
if [ "$(printf '%s\n1.25.1\n' "$NGINX_VER" | sort -V | head -n1)" = "1.25.1" ]; then
    LISTEN_SSL="listen 443 ssl;
    listen [::]:443 ssl;
    http2 on;"
else
    LISTEN_SSL="listen 443 ssl http2;
    listen [::]:443 ssl http2;"
fi

cat > "${NGINX_AVAILABLE}/${DOMAIN}.conf" <<NGINXHTTPS
server {
    listen 80;
    listen [::]:80;
    server_name ${DOMAIN};

    location /.well-known/acme-challenge/ {
        root /var/www/certbot;
    }

    location / {
        return 301 https://\$host\$request_uri;
    }
}

server {
    ${LISTEN_SSL}
    server_name ${DOMAIN};

    ssl_certificate     /etc/letsencrypt/live/${DOMAIN}/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/${DOMAIN}/privkey.pem;
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_ciphers HIGH:!aNULL:!MD5;
    ssl_prefer_server_ciphers on;
    ssl_session_cache shared:SSL:10m;
    ssl_session_timeout 10m;

    server_tokens off;
    add_header X-Content-Type-Options "nosniff" always;
    add_header X-Frame-Options "SAMEORIGIN" always;
    add_header Referrer-Policy "strict-origin-when-cross-origin" always;

    charset utf-8;
    gzip on;
    gzip_types text/css application/javascript image/svg+xml application/xml text/plain;

    root ${WEBROOT};
    index index.html;

    error_page 404 /404.html;
    location = /404.html { internal; }

    location ~* \.(css|js|svg)\$ {
        expires 30d;
        try_files \$uri =404;
    }

    location ~ /\.(?!well-known) {
        return 404;
    }

    location / {
        try_files \$uri \$uri/ =404;
    }
}
NGINXHTTPS

nginx -t
systemctl reload nginx

echo "  -> HTTPS включён"

# ------------------------------------------------------------
# Скрипт автообновления сертификата
# ------------------------------------------------------------
RENEW_SCRIPT="/usr/local/bin/renew-${DOMAIN}.sh"
cat > "${RENEW_SCRIPT}" <<RENEW
#!/bin/bash
certbot renew --webroot -w /var/www/certbot --quiet --deploy-hook "systemctl reload nginx"
RENEW
chmod +x "${RENEW_SCRIPT}"

CRON_LINE="0 3 * * * ${RENEW_SCRIPT} >> /var/log/renew-${DOMAIN}.log 2>&1"
( crontab -l 2>/dev/null | grep -v "${RENEW_SCRIPT}" ; echo "${CRON_LINE}" ) | crontab -

echo "  -> Автообновление сертификата настроено (cron, 03:00 ежедневно)"
echo "  -> Скрипт обновления: ${RENEW_SCRIPT}"

# ------------------------------------------------------------
# Итог
# ------------------------------------------------------------
echo
line
paint "$C_GREEN$C_BOLD" "✓ ГОТОВО"
line
echo " Домен:        https://${DOMAIN}/"
echo " Компания:     ${COMPANY}"
echo " Сид:          ${SEED}"
echo " Файлы сайта:  ${WEBROOT}"
echo " nginx конфиг: ${NGINX_AVAILABLE}/${DOMAIN}.conf"
echo " Сертификат:   /etc/letsencrypt/live/${DOMAIN}/"
echo " Автообновление серта: ${RENEW_SCRIPT} (cron, ежедневно 03:00)"
echo "================================================"
__HONEYPOT_GENERATOR_SOURCE_20261027__
  {
    cat <<'HONEYPOT_WRAPPER'
#!/usr/bin/env bash
set -e
DOMAIN="${1:?domain required}"
export HONEYPOT_DRYRUN=1
export HONEYPOT_WEBROOT="/var/www/honeypot/${DOMAIN}"
HONEYPOT_WRAPPER
    cat "$D/honeypot-generator.source.sh"
  } > "$D/honeypot.sh"

  cat > "$D/pkgs.sh" <<'EOF'
set -Eeuo pipefail
export DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=a NEEDRESTART_SUSPEND=1 APT_LISTCHANGES_FRONTEND=none
APT=(apt-get -o DPkg::Lock::Timeout=300 -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold)
run_apt() {
  local label="$1"; shift
  echo "[APT] $label"
  if timeout --foreground 1800 "${APT[@]}" "$@"; then
    echo "[OK] $label"
  else
    rc=$?
    if [ "$rc" -eq 124 ]; then echo "[ERROR] $label: таймаут 30 минут; проверьте блокировки apt/dpkg и /var/log/apt/term.log" >&2
    else echo "[ERROR] $label: код завершения $rc; последние сообщения apt/dpkg:" >&2; tail -n 35 /var/log/apt/term.log /var/log/dpkg.log 2>/dev/null || true; fi
    exit "$rc"
  fi
}
run_apt "обновление списков" update -qq
run_apt "обновление пакетов" upgrade -y
run_apt "dist-upgrade (лимит 30 минут)" dist-upgrade -y
run_apt "установка зависимостей" install -y curl wget sudo nginx certbot dnsutils unzip ufw ca-certificates openssl python3 gzip
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
XUI_PATH="${2:-}"
XUI_PATH="${XUI_PATH#/}"
XUI_PATH="${XUI_PATH%/}"
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

    # Отдельный путь панели 3x-ui; корень домена остаётся обычным сайтом.
    location = /$XUI_PATH { return 301 /$XUI_PATH/; }
    location ^~ /$XUI_PATH/ {
        proxy_pass http://127.0.0.1:999;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
    }

    root /var/www/honeypot/$DOMAIN;
    index index.html;
    error_page 404 /404.html;
    location = /404.html { internal; }
    location ~ /\.(?!well-known) { return 404; }
    location / {
        try_files \$uri \$uri/ =404;
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

  # fail2ban (из «Подготовить сервер») не должен банить RELAY при повторных SSH-подключениях скрипта
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

# ───────────────────────── подготовка сервера (бывший preServer.sh) ─────────────────────────
# Выполняется на ЭТОМ сервере. PREP_ROOT — только для тестов (префикс путей).
PR="${PREP_ROOT:-}"
PREP_MARKER_DIR="$PR/var/lib/preserver"
PREP_MARKER_FILE="$PREP_MARKER_DIR/.preserver-ran"   # тот же путь, что у автономного preServer.sh

# Убираем противоречащие настройки в drop-in конфигах sshd: Include стоит в начале sshd_config,
# и sshd берёт ПЕРВОЕ встреченное значение — правки в основном файле иначе молча игнорируются.
neutralize_sshd_dropins() {
  local f
  for f in "$PR"/etc/ssh/sshd_config.d/*.conf; do
    [ -f "$f" ] || continue
    [ "$(basename "$f")" = "99-preserver.conf" ] && continue
    sed -i -E 's/^[[:space:]]*(Port|PermitRootLogin|PasswordAuthentication|PubkeyAuthentication)\b/# [preServer disabled] \1/' "$f"
    if ! grep -qE '^[^#[:space:]]' "$f" 2>/dev/null; then
      rm -f "$f"
      info "удалён пустой drop-in конфиг: $f"
    fi
  done
}

disable_ssh_socket_activation() {
  if systemctl list-unit-files 2>/dev/null | grep -q '^ssh\.socket'; then
    if systemctl is-enabled ssh.socket &>/dev/null || systemctl is-active ssh.socket &>/dev/null; then
      systemctl stop ssh.socket >/dev/null 2>&1 || true
      systemctl disable ssh.socket >/dev/null 2>&1 || true
      info "обнаружена socket activation (ssh.socket) — отключена, чтобы смена порта применялась без перезагрузки"
    fi
  fi
}

verify_and_restart_sshd() {
  local want_port="$1" want_pwauth="$2" want_rootlogin="$3"
  mkdir -p /run/sshd
  chmod 0755 /run/sshd

  local eff
  eff="$(sshd -T 2>&1)" || {
    fail "sshd -T завершился с ошибкой, перезапуск отменён"
    printf '    Вывод sshd -T:\n%s\n' "$eff"
    return 1
  }

  local eff_port eff_pwauth eff_rootlogin eff_ports
  eff_ports=$(awk '/^port /{print $2}' <<< "$eff")
  eff_port=$(tr '\n' ',' <<< "$eff_ports")
  eff_port="${eff_port%,}"
  eff_pwauth=$(awk '/^passwordauthentication /{print $2; exit}' <<< "$eff")
  eff_rootlogin=$(awk '/^permitrootlogin /{print $2; exit}' <<< "$eff")

  local nw="$want_rootlogin" ne="$eff_rootlogin"
  [ "$nw" = "prohibit-password" ] && nw="without-password"
  [ "$ne" = "prohibit-password" ] && ne="without-password"

  if ! grep -qx "$want_port" <<< "$eff_ports" || [ "$eff_pwauth" != "$want_pwauth" ] || [ "$ne" != "$nw" ]; then
    fail "эффективный конфиг sshd НЕ совпадает с ожидаемым (port=$eff_port pwauth=$eff_pwauth rootlogin=$eff_rootlogin)"
    echo "    Проверьте /etc/ssh/sshd_config.d/*.conf вручную. Перезапуск sshd ОТМЕНЁН."
    return 1
  fi

  local svc="ssh"
  systemctl list-unit-files | grep -q "sshd.service" && svc="sshd"

  disable_ssh_socket_activation

  # остановка ssh.socket/ssh.service удаляет /run/sshd — создаём заново перед sshd -t
  mkdir -p /run/sshd
  chmod 0755 /run/sshd

  if ! sshd -t 2>&1; then
    fail "sshd -t: синтаксическая ошибка, перезапуск отменён"
    return 1
  fi

  systemctl enable "$svc" >/dev/null 2>&1 || true
  systemctl restart "$svc" 2>/dev/null || systemctl restart ssh 2>/dev/null || systemctl restart sshd 2>/dev/null || true
  ok "sshd перезапущен, эффективный конфиг подтверждён (port=$eff_port pwauth=$eff_pwauth rootlogin=$eff_rootlogin)"
  return 0
}

prep_rollback() {
  local cfg="$PR/etc/ssh/sshd_config" old_port=""
  echo
  echo "${B}Откат настроек подготовки сервера${R}"
  thin
  [ -f "$PREP_MARKER_FILE" ] && old_port="$(awk -F= '/^ssh_port=/{print $2; exit}' "$PREP_MARKER_FILE" 2>/dev/null || true)"

  mkdir -p /run/sshd
  chmod 0755 /run/sshd

  if [ -f "$cfg" ]; then
    cp "$cfg" "${cfg}.bak.$(date +%s)"
    neutralize_sshd_dropins

    if grep -qE '^\s*#?\s*Port\b' "$cfg"; then
      sed -i -E 's/^\s*#?\s*Port\b.*/Port 22/' "$cfg"
    else
      echo "Port 22" >> "$cfg"
    fi
    sed -i -E 's/^\s*#?\s*PermitRootLogin\b.*/PermitRootLogin yes/' "$cfg"
    sed -i -E 's/^\s*#?\s*PasswordAuthentication\b.*/PasswordAuthentication yes/' "$cfg"
    sed -i -E 's/^\s*#?\s*PrintMotd\b.*/PrintMotd yes/' "$cfg"
    sed -i -E 's/^\s*#?\s*PrintLastLog\b.*/PrintLastLog yes/' "$cfg"

    if passwd -S root 2>/dev/null | awk '{print $2}' | grep -qE '^(L|LK|NP)$'; then
      warn "у root не задан пароль. Вход по паролю не заработает без: passwd root"
    fi

    if command -v ufw &>/dev/null; then
      ufw allow 22/tcp comment 'SSH (preServer rollback)' >/dev/null 2>&1 || true
      if [[ "$old_port" =~ ^[0-9]+$ ]] && [ "$old_port" != "22" ]; then
        ufw --force delete allow "${old_port}/tcp" >/dev/null 2>&1 || true
        info "правило ufw для порта $old_port (подготовка) удалено, остальные правила не тронуты"
      fi
    fi

    verify_and_restart_sshd 22 yes yes || warn "порт/пароль отредактированы, но перезапуск не выполнен — проверьте вручную!"
  fi

  if dpkg -s fail2ban &>/dev/null; then
    systemctl stop fail2ban >/dev/null 2>&1 || true
    systemctl disable fail2ban >/dev/null 2>&1 || true
    apt-get purge -y fail2ban >/dev/null 2>&1 || true
    rm -f "$PR/etc/fail2ban/jail.local"
    ok "fail2ban удалён"
  fi

  if dpkg -s fastfetch &>/dev/null; then
    apt-get purge -y fastfetch >/dev/null 2>&1 || true
    ok "fastfetch удалён"
  elif command -v fastfetch &>/dev/null; then
    rm -f "$(command -v fastfetch)"
  fi
  rm -rf "$PR/root/.config/fastfetch"
  rm -f "$PR/etc/profile.d/fastfetch-ssh.sh"
  if [ -d "$PR/etc/update-motd.d" ]; then
    chmod +x "$PR"/etc/update-motd.d/* 2>/dev/null || true
  fi

  rm -f "$PR/usr/local/sbin/daily-security-update.sh"
  rm -f "$PR/etc/cron.d/daily-security-update"
  rm -f "$PREP_MARKER_FILE"

  echo
  ok "откат завершён"
  [ -f "$MARKER_FILE" ] && info "установка туннеля/панели этим откатом не затрагивается (для неё — пункт «Отменить установку»)"
  return 0
}

prep_fastfetch_ppa() {
  add-apt-repository -y ppa:zhangsongcui3371/fastfetch &&
    apt-get -o DPkg::Lock::Timeout=300 update -qq &&
    apt-get -o DPkg::Lock::Timeout=300 install -y fastfetch
}

prep_fastfetch_deb() {
  local arch url tmp
  arch=$(dpkg --print-architecture)
  url=$(curl -fsSL "https://api.github.com/repos/fastfetch-cli/fastfetch/releases/latest" |
    grep "browser_download_url" | grep "linux-${arch}.deb" | head -1 | cut -d '"' -f 4) || true
  [ -n "$url" ] || return 1
  tmp=$(mktemp)
  curl -fsSL "$url" -o "$tmp"
  dpkg -i "$tmp" || apt-get install -f -y
  rm -f "$tmp"
}

run_prepare() {
  STEP=0; TOTAL=7
  if [ -f "$PREP_MARKER_FILE" ]; then
    echo
    warn "обнаружена метка предыдущей подготовки сервера:"
    sed 's/^/     /' "$PREP_MARKER_FILE"
    echo
    if confirm "Выполнить откат настроек подготовки?"; then
      prep_rollback
    else
      echo "  Отменено."
    fi
    return 0
  fi

  echo
  echo "${B}Подготовка сервера${R}"
  thin
  info "обновление системы, fail2ban, SSH (свой порт, вход только по ключу), автообновления, fastfetch"
  info "выполняется на ЭТОМ сервере: запустите скрипт отдельно на RELAY и на BACKEND"
  [ -f "$MARKER_FILE" ] && warn "установка туннеля/панели уже выполнена: после смены SSH-порта укажите новый порт при следующих запусках"
  confirm "Начать подготовку?" || { echo "  Отменено."; return 0; }

  export DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=a NEEDRESTART_SUSPEND=1 APT_LISTCHANGES_FRONTEND=none
  export PYTHONWARNINGS="ignore::SyntaxWarning"
  local APT_OPTS=(-o DPkg::Lock::Timeout=300 -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold)

  # [1] пакетная база
  section "Проверка пакетной базы"
  if [ -d "$PR/var/lib/dpkg/updates" ] && ls "$PR"/var/lib/dpkg/updates/* >/dev/null 2>&1; then
    warn "обнаружены незавершённые операции dpkg, восстанавливаю..."
    if pgrep -x dpkg >/dev/null 2>&1 || pgrep -x apt-get >/dev/null 2>&1; then
      info "apt/dpkg сейчас занят другим процессом — блокировки не трогаю, ждём освобождения"
    else
      rm -f /var/lib/dpkg/lock /var/lib/dpkg/lock-frontend /var/cache/apt/archives/lock /var/lib/apt/lists/lock
    fi
    step_run -s "dpkg --configure -a" dpkg --configure -a --force-confdef --force-confold
    rm -f "$PR"/var/lib/dpkg/updates/*
    step_run -s "dpkg --configure -a (повторно)" dpkg --configure -a
  fi
  ok "пакетная база в порядке"

  # [2] обновление системы
  section "Обновление системы"
  step_run "Обновление списков пакетов" apt-get "${APT_OPTS[@]}" update -qq || die "apt update не удался"
  step_run "Обновление пакетов (upgrade)" apt-get "${APT_OPTS[@]}" upgrade -y || die "apt upgrade не удался"
  step_run "Обновление дистрибутива (dist-upgrade, лимит 30 минут)" timeout --foreground 1800 apt-get "${APT_OPTS[@]}" dist-upgrade -y || {
    rc=$?
    if [ "$rc" -eq 124 ]; then die "apt dist-upgrade завис или превысил лимит 30 минут. Проверьте /var/log/apt/term.log и /var/log/dpkg.log; возможен незавершённый dpkg или запрос действия.";
    else die "apt dist-upgrade завершился с ошибкой (код $rc). Подробности — в $LOG и /var/log/apt/term.log"; fi
  }
  step_run "Удаление ненужных пакетов" apt-get "${APT_OPTS[@]}" autoremove -y || warn "autoremove не выполнен"

  # [3] утилиты и fail2ban
  section "Установка утилит"
  local PACKAGES=(unattended-upgrades fail2ban htop iotop nethogs curl wget git cron ripgrep)
  local missing=() pkg
  for pkg in "${PACKAGES[@]}"; do
    dpkg -s "$pkg" &>/dev/null || missing+=("$pkg")
  done
  if [ ${#missing[@]} -gt 0 ]; then
    step_run "Установка пакетов: ${missing[*]}" apt-get "${APT_OPTS[@]}" install -y --no-install-recommends "${missing[@]}" || die "не удалось установить пакеты"
  else
    ok "все утилиты уже установлены"
  fi
  mkdir -p "$PR/etc/fail2ban"
  cat > "$PR/etc/fail2ban/jail.local" << 'F2BEOF'
[sshd]
enabled = true
port = 1119
backend = systemd
maxretry = 5
bantime = 1h
findtime = 10m
F2BEOF
  systemctl enable fail2ban >/dev/null 2>&1 || true
  systemctl restart fail2ban >/dev/null 2>&1 || true
  systemctl enable cron >/dev/null 2>&1 || true
  systemctl start cron >/dev/null 2>&1 || true
  ok "fail2ban и утилиты настроены"

  # [4] SSH
  section "Настройка SSH"
  mkdir -p /run/sshd
  chmod 0755 /run/sshd
  local cfg="$PR/etc/ssh/sshd_config" in_port ssh_port key tmpf p
  while true; do
    ask in_port "Введите внутренний порт SSH" "1119"
    ssh_port="$in_port"
    if [[ "$ssh_port" =~ ^[0-9]+$ ]] && [ "$ssh_port" -ge 1 ] && [ "$ssh_port" -le 65535 ]; then
      if command -v ss &>/dev/null && ss -tulnp | grep ":${ssh_port} " | grep -vq sshd; then
        warn "порт $ssh_port занят."
        confirm "Продолжить?" && break || continue
      fi
      break
    else
      fail "порт должен быть числом 1-65535"
    fi
  done
  ok "выбран порт SSH: $ssh_port"

  while true; do
    rd -r -p "${B}?${R} Введите SSH публичный ключ: " key
    if [[ "$key" =~ ^(ssh-rsa|ssh-ed25519|ecdsa-sha2-nistp256|ecdsa-sha2-nistp384|ecdsa-sha2-nistp521)\  ]]; then
      break
    else
      fail "неверный формат ключа"
    fi
  done
  ok "ключ принят"

  if [ -f "$cfg" ]; then
    info "sshd будет слушать только порт: $ssh_port (старые порты, включая 22, не сохраняются)"
    cp "$cfg" "${cfg}.bak.$(date +%s)"
    ls -1t "${cfg}".bak.* 2>/dev/null | tail -n +6 | xargs -r rm -f
    neutralize_sshd_dropins

    # Port-строка — в начало файла (чтобы не попасть внутрь блока Match)
    sed -i -E '/^[[:space:]]*#?[[:space:]]*Port[[:space:]]/d' "$cfg"
    tmpf=$(mktemp)
    echo "Port $ssh_port" | cat - "$cfg" > "$tmpf"
    cat "$tmpf" > "$cfg"
    rm -f "$tmpf"

    sed -i 's/^#\?PermitRootLogin.*/PermitRootLogin prohibit-password/' "$cfg"
    sed -i 's/^#\?PubkeyAuthentication.*/PubkeyAuthentication yes/' "$cfg"
    sed -i 's/^#\?PasswordAuthentication.*/PasswordAuthentication no/' "$cfg"
    sed -i 's/^#\?UseDNS.*/UseDNS no/' "$cfg"

    mkdir -p "$PR/root/.ssh" && chmod 700 "$PR/root/.ssh"
    grep -qF "$key" "$PR/root/.ssh/authorized_keys" 2>/dev/null || echo "$key" >> "$PR/root/.ssh/authorized_keys"
    chmod 600 "$PR/root/.ssh/authorized_keys"

    if [ -f "$PR/etc/fail2ban/jail.local" ]; then
      sed -i "s/^port = .*/port = $ssh_port/" "$PR/etc/fail2ban/jail.local"
      systemctl restart fail2ban >/dev/null 2>&1 || true
    fi

    if command -v ufw &>/dev/null; then
      ufw allow "${ssh_port}/tcp" comment 'SSH (preServer)' >/dev/null 2>&1 || true
      ok "порт $ssh_port открыт в ufw"
    fi

    verify_and_restart_sshd "$ssh_port" no prohibit-password || die "ошибка применения настроек SSH: проверьте конфиги вручную"
  else
    warn "файл $cfg не найден — настройка SSH пропущена"
  fi

  # [5] автообновления
  section "Автообновления"
  local UPDATE_SCRIPT="$PR/usr/local/sbin/daily-security-update.sh"
  mkdir -p "$(dirname "$UPDATE_SCRIPT")" "$PR/etc/cron.d"
  cat > "$UPDATE_SCRIPT" << 'EOF'
#!/bin/bash
export DEBIAN_FRONTEND=noninteractive
export NEEDRESTART_MODE=a
LOG_FILE="/var/log/auto-update.log"
{
    echo "===== $(date '+%F %T') start ====="
    apt-get -o DPkg::Lock::Timeout=600 update -qq
    apt-get -o DPkg::Lock::Timeout=600 upgrade -y -o Dpkg::Options::="--force-confdef" -o Dpkg::Options::="--force-confold"
    apt-get autoremove -y
    echo "===== $(date '+%F %T') done ====="
} >> "$LOG_FILE" 2>&1
EOF
  chmod 0755 "$UPDATE_SCRIPT"
  cat > "$PR/etc/cron.d/daily-security-update" << EOF
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
0 3 * * * root /usr/local/sbin/daily-security-update.sh
EOF
  chmod 0644 "$PR/etc/cron.d/daily-security-update"
  systemctl is-active --quiet cron || systemctl start cron >/dev/null 2>&1 || true
  ok "автообновления настроены (ежедневно в 03:00)"

  # [6] fastfetch
  section "Fastfetch"
  local ff=false
  if command -v fastfetch &>/dev/null; then
    ff=true
    ok "fastfetch уже установлен"
  else
    if command -v add-apt-repository &>/dev/null; then
      step_run -s "Установка Fastfetch (PPA)" prep_fastfetch_ppa && ff=true
    fi
    if ! $ff; then
      step_run -s "Установка Fastfetch (.deb с GitHub)" prep_fastfetch_deb && ff=true
    fi
  fi

  if $ff; then
    mkdir -p "$PR/root/.config/fastfetch"
    cat > "$PR/root/.config/fastfetch/logo.txt" << 'ASCII_LOGO'
+------------------------------+
| +--------------------------+ |
| | +----------------------+ | |
| | | +------------------+ | | |
| | | | +--------------+ | | | |
| | | | | +----------+ | | | | |
| | | | | |          | | | | | |
| | | | | |    ●●    | | | | | |
| | | | | |          | | | | | |
| | | | | +----------+ | | | | |
| | | | +--------------+ | | | |
| | | +------------------+ | | |
| | +----------------------+ | |
| +--------------------------+ |
+------------------------------+
ASCII_LOGO

    cat > "$PR/root/.config/fastfetch/config.jsonc" << 'FFCONFIG'
{
    "$schema": "https://github.com/fastfetch-cli/fastfetch/raw/dev/doc/json_schema.json",
    "logo": {
        "type": "file",
        "source": "/root/.config/fastfetch/logo.txt",
        "padding": { "top": 1, "left": 2, "right": 4 }
    },
    "display": {
        "color": { "keys": "blue", "title": "bright_magenta", "separator": "white" }
    },
    "modules": [
        { "type": "custom", "format": "\u001b[97m┌──────────────────────────────────────Hardware──────────────────────────────────────┐\u001b[0m" },
        { "type": "host", "key": "▣ PC : ", "keyColor": "green" },
        { "type": "cpu", "key": "   ├▢ CPU: ", "keyColor": "green" },
        { "type": "cpuusage", "key": "   ├▢ Usage: ", "keyColor": "green" },
        { "type": "loadavg", "key": "   ├▢ Load: ", "keyColor": "green" },
        { "type": "gpu", "key": "   ├▢ GPU: ", "keyColor": "green" },
        { "type": "memory", "key": "   ├▢ RAM: ", "keyColor": "green" },
        { "type": "swap", "key": "   ├▢ Swap: ", "keyColor": "green" },
        { "type": "disk", "key": "   ├▢ Disk: ", "keyColor": "green" },
        { "type": "custom", "format": "\u001b[97m└────────────────────────────────────────────────────────────────────────────────────┘\u001b[0m" },
        "break",
        { "type": "custom", "format": "\u001b[97m┌──────────────────────────────────────Software──────────────────────────────────────┐\u001b[0m" },
        { "type": "os", "key": "▣ OS : ", "keyColor": "yellow" },
        { "type": "kernel", "key": "   ├▢ Kernel: ", "keyColor": "yellow" },
        { "type": "packages", "key": "   ├▢ Packages: ", "keyColor": "yellow" },
        { "type": "shell", "key": "   ├▢ Shell: ", "keyColor": "yellow" },
        { "type": "custom", "format": "\u001b[97m└────────────────────────────────────────────────────────────────────────────────────┘\u001b[0m" },
        "break",
        { "type": "custom", "format": "\u001b[97m┌───────────────────────────────────────Network──────────────────────────────────────┐\u001b[0m" },
        { "type": "localip", "key": "▣ IP : ", "keyColor": "cyan" },
        { "type": "command", "key": "   └▢ Location: ", "keyColor": "cyan", "text": "curl -s --max-time 2 https://ipinfo.io/city" },
        { "type": "custom", "format": "\u001b[97m└────────────────────────────────────────────────────────────────────────────────────┘\u001b[0m" },
        "break",
        { "type": "uptime", "key": "▣ UP : ", "keyColor": "magenta" },
        { "type": "datetime", "key": "   └⏰ : ", "keyColor": "magenta" },
        { "type": "colors", "paddingLeft": 2, "symbol": "circle" }
    ]
}
FFCONFIG

    if [ -d "$PR/etc/update-motd.d" ]; then
      chmod -x "$PR"/etc/update-motd.d/* 2>/dev/null || true
    fi
    truncate -s 0 "$PR/etc/motd" 2>/dev/null || true
    if [ -f "$cfg" ]; then
      if grep -q "^PrintMotd" "$cfg" 2>/dev/null; then
        sed -i 's/^PrintMotd.*/PrintMotd no/' "$cfg"
      else
        echo "PrintMotd no" >> "$cfg"
      fi
    fi

    mkdir -p "$PR/etc/profile.d"
    cat > "$PR/etc/profile.d/fastfetch-ssh.sh" << 'PROFEOF'
if [ -n "${FASTFETCH_RAN:-}" ]; then return 0; fi
if [ -n "$SSH_CONNECTION" ] && command -v fastfetch >/dev/null 2>&1; then
    fastfetch
    export FASTFETCH_RAN=1
fi
PROFEOF
    chmod 0644 "$PR/etc/profile.d/fastfetch-ssh.sh"
    ok "fastfetch настроен"
  fi

  # [7] итог
  section "Завершение"
  ok "подготовка сервера завершена"
  kv "SSH port" "${ssh_port:-пропущено}"
  kv "Fail2ban" "активен"
  kv "Fastfetch" "$($ff && echo 'установлен' || echo 'пропущен')"
  kv "Log" "$LOG"
  mkdir -p "$PREP_MARKER_DIR"
  {
    echo "version=$VERSION"
    echo "ran_at=$(date '+%F %T')"
    echo "ssh_port=${ssh_port:-skipped}"
  } > "$PREP_MARKER_FILE"
  warn "проверьте вход по ключу на новом порту ($ssh_port) ДО перезагрузки!"

  if [ -z "$PR" ] && [ -t 1 ] && [ -e /dev/tty ]; then
    echo
    if confirm "Перезагрузить сейчас?"; then
      reboot
    fi
  fi
  return 0
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

  # [6] Генерация реального сайта для корня домена
  section "Honeypot: генерация сайта"
  step_run "Генерация сайта в /var/www/honeypot/$DOMAIN" rscript "$TMPD/honeypot.sh" "$DOMAIN" || die "не удалось сгенерировать Honeypot"

  # [7]
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
    step_run "nginx: сертификат, пути подписки из панели, автопродление" rscript "$TMPD/nginx-final.sh" "$DOMAIN" "$xw" || die "не удалось включить финальный конфиг nginx"
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

  rscript "$TMPD/f2b-ignore.sh" "$RELAY_IP" >>"$LOG" 2>&1 || true

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

  # [9] Генерация реального сайта для корня домена
  section "BACKEND: Honeypot"
  step_run "Генерация сайта в /var/www/honeypot/$DOMAIN" rscript "$TMPD/honeypot.sh" "$DOMAIN" || die "не удалось сгенерировать Honeypot"

  # [10] nginx временный
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
    step_run "nginx: сертификат, пути подписки из панели, автопродление" rscript "$TMPD/nginx-final.sh" "$DOMAIN" "$xw" || die "не удалось включить финальный конфиг nginx"
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
    prepare) run_prepare ;;
    install_backend) run_install_backend ;;
    install_relay) run_install ;;
    test) run_test ;;
    uninstall) do_uninstall ;;
  esac
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  main "$@"
fi
