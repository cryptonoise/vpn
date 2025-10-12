#!/bin/bash
set -e

if [ -f /root/.server_secured ]; then
    printf "✅ Сервер уже защищён. Повторный запуск не требуется.\n"
    exit 0
fi

# === Универсальный спиннер (работает и без tty) ===
run_with_spinner() {
    local msg="$1"
    shift
    local cmd=("$@")
    local spin=('⠋' '⠙' '⠹' '⠸' '⠼' '⠴' '⠦' '⠧' '⠇' '⠏')
    printf "%-40s" "$msg" >/dev/null &  # Выравнивание по 40 символам
    local pid
    "${cmd[@]}" &
    pid=$!
    local i=0
    while kill -0 "$pid" 2>/dev/null; do
        printf "\r%-40s %s" "$msg" "${spin[$((i++ % ${#spin[@]}))]}"
        sleep 0.1
    done
    wait "$pid"
    local code=$?
    if [ $code -eq 0 ]; then
        printf "\r%-40s ✅\n" "$msg"
    else
        printf "\r%-40s ❌\n" "$msg"
    fi
}

printf "🚀 Начинаю базовую настройку безопасности сервера...\n\n"

run_with_spinner "🔄 Обновляю систему..." bash -c "apt update -qq && DEBIAN_FRONTEND=noninteractive apt upgrade -y -qq && apt autoremove -y -qq"
run_with_spinner "🛡️ Устанавливаю unattended-upgrades..." bash -c "apt install -y -qq unattended-upgrades && echo 'unattended-upgrades unattended-upgrades/enable_auto_updates boolean true' | debconf-set-selections && dpkg-reconfigure -f noninteractive unattended-upgrades"
run_with_spinner "🚫 Устанавливаю fail2ban..." bash -c "apt install -y -qq fail2ban && systemctl enable fail2ban --quiet && systemctl start fail2ban --quiet"
run_with_spinner "📊 Устанавливаю htop, iotop, nethogs..." bash -c "apt install -y -qq htop iotop nethogs"

touch /root/.server_secured
printf "\n✅ Готово! Сервер защищён и готов к работе.\n"
