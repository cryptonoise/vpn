#!/bin/bash

set -e

# === Проверка: уже настроен? ===
if [ -f /root/.server_secured ]; then
    echo "✅ Сервер уже защищён. Повторный запуск не требуется."
    exit 0
fi

# === Функция: спиннер в одной строке ===
run_with_spinner() {
    local msg="$1"
    shift
    local cmd=("$@")

    echo -n "$msg "

    # Запускаем команду в подоболочке
    (
        "${cmd[@]}" >/dev/null 2>&1
    ) &
    local pid=$!

    local spinstr='⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏'
    local i=0
    while kill -0 "$pid" 2>/dev/null; do
        printf "%s" "${spinstr:$((i % ${#spinstr})):1}"
        sleep 0.15
        printf "\b"
        ((i++))
    done

    wait "$pid"
    printf "✅\n"
}

echo "🚀 Начинаю базовую настройку безопасности сервера..."
echo

# 1. Обновление системы
run_with_spinner "🔄 Обновляю систему..." \
    bash -c "sudo apt update && sudo DEBIAN_FRONTEND=noninteractive apt upgrade -y && sudo DEBIAN_FRONTEND=noninteractive apt dist-upgrade -y && sudo apt autoremove -y"

# 2. Автоматические обновления безопасности
run_with_spinner "🛡️ Устанавливаю unattended-upgrades..." \
    bash -c "sudo apt install -y --no-install-recommends unattended-upgrades && echo 'unattended-upgrades unattended-upgrades/enable_auto_updates boolean true' | sudo debconf-set-selections && sudo dpkg-reconfigure -f noninteractive unattended-upgrades"

# 3. Защита от брутфорса
run_with_spinner "🛡️ Устанавливаю fail2ban..." \
    bash -c "sudo apt install -y --no-install-recommends fail2ban && sudo systemctl enable fail2ban --quiet && sudo systemctl start fail2ban --quiet"

# 4. Антивирус/руткит сканеры
run_with_spinner "🔍 Устанавливаю rkhunter и chkrootkit..." \
    bash -c "sudo apt install -y --no-install-recommends rkhunter chkrootkit && sudo rkhunter --update --quiet && sudo rkhouter --propupd --quiet"

# 5. Утилиты мониторинга
run_with_spinner "📊 Устанавливаю htop, iotop, nethogs..." \
    bash -c "sudo apt install -y --no-install-recommends htop iotop nethogs"

touch /root/.server_secured

echo
echo "✅ Готово! Сервер защищён и готов к работе."
