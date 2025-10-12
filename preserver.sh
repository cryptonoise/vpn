#!/bin/bash

set -e

# === Проверка: уже настроен? ===
if [ -f /root/.server_secured ]; then
    echo "✅ Сервер уже защищён. Повторный запуск не требуется."
    exit 0
fi

# === Функция: спиннер с поддержкой Юникода и очисткой ===
run_with_spinner() {
    local msg="$1"
    shift
    local cmd=("$@")

    echo -ne "$msg "
    local spinstr=('⠋' '⠙' '⠹' '⠸' '⠼' '⠴' '⠦' '⠧' '⠇' '⠏')
    local i=0

    "${cmd[@]}" >/tmp/spinner_output.log 2>&1 &
    local pid=$!

    while kill -0 "$pid" 2>/dev/null; do
        printf "\r%s %s" "$msg" "${spinstr[$((i++ % ${#spinstr[@]}))]}"
        sleep 0.1
    done

    wait "$pid"
    local status=$?
    if [ $status -eq 0 ]; then
        printf "\r%s ✅\n" "$msg"
    else
        printf "\r%s ❌ (ошибка, см. /tmp/spinner_output.log)\n" "$msg"
    fi
}

echo "🚀 Начинаю базовую настройку безопасности сервера..."
echo

# 1. Обновление системы
run_with_spinner "🔄 Обновляю систему..." \
    bash -c "apt update -qq && DEBIAN_FRONTEND=noninteractive apt upgrade -y -qq && apt autoremove -y -qq"

# 2. Автоматические обновления безопасности
run_with_spinner "🛡️ Устанавливаю unattended-upgrades..." \
    bash -c "apt install -y -qq unattended-upgrades && \
    echo 'unattended-upgrades unattended-upgrades/enable_auto_updates boolean true' | debconf-set-selections && \
    dpkg-reconfigure -f noninteractive unattended-upgrades"

# 3. Защита от брутфорса
run_with_spinner "🚫 Устанавливаю fail2ban..." \
    bash -c "apt install -y -qq fail2ban && systemctl enable fail2ban --quiet && systemctl start fail2ban --quiet"

# 4. Антивирус/руткит-сканеры
run_with_spinner "🔍 Устанавливаю rkhunter и chkrootkit..." \
    bash -c "apt install -y -qq rkhunter chkrootkit && rkhunter --update --quiet && rkhunter --propupd --quiet"

# 5. Утилиты мониторинга
run_with_spinner "📊 Устанавливаю htop, iotop, nethogs..." \
    bash -c "apt install -y -qq htop iotop nethogs"

# === Флаг успешной настройки ===
touch /root/.server_secured

echo
echo "✅ Готово! Сервер защищён и готов к работе."
echo "📄 Подробности: /tmp/spinner_output.log"
