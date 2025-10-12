#!/bin/bash

set -e

# Функция с надёжной анимацией
run_with_spinner() {
    local msg="$1"
    local cmd="$2"

    echo -n "$msg "

    # Запускаем команду в фоне
    eval "$cmd" >/dev/null 2>&1 &
    local pid=$!

    local spinstr='⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏'
    local i=0

    # Анимация пока процесс жив
    while kill -0 "$pid" 2>/dev/null; do
        printf "%s" "${spinstr:$((i % ${#spinstr})):1}"
        sleep 0.1
        printf "\b"
        ((i++))
    done

    # Ждём завершения (на случай race condition)
    wait "$pid"

    # Заменяем спиннер на ✅ и переходим на новую строку
    printf "✅\n"
}

echo "🚀 Начинаю базовую настройку безопасности сервера..."
echo

# 1. Обновление системы
run_with_spinner "🔄 Обновляю систему..." \
    "sudo apt update && sudo DEBIAN_FRONTEND=noninteractive apt upgrade -y && sudo DEBIAN_FRONTEND=noninteractive apt dist-upgrade -y && sudo apt autoremove -y"

# 2. Автоматические обновления безопасности
run_with_spinner "🛡️ Устанавливаю unattended-upgrades..." \
    "sudo apt install -y --no-install-recommends unattended-upgrades && echo 'unattended-upgrades unattended-upgrades/enable_auto_updates boolean true' | sudo debconf-set-selections && sudo dpkg-reconfigure -f noninteractive unattended-upgrades"

# 3. Защита от брутфорса
run_with_spinner "🛡️ Устанавливаю fail2ban..." \
    "sudo apt install -y --no-install-recommends fail2ban && sudo systemctl enable fail2ban --quiet && sudo systemctl start fail2ban --quiet"

# 4. Антивирус/руткит сканеры
run_with_spinner "🔍 Устанавливаю rkhunter и chkrootkit..." \
    "sudo apt install -y --no-install-recommends rkhunter chkrootkit && sudo rkhunter --update --quiet && sudo rkhunter --propupd --quiet"

# 5. Утилиты мониторинга
run_with_spinner "📊 Устанавливаю htop, iotop, nethogs..." \
    "sudo apt install -y --no-install-recommends htop iotop nethogs"

echo
echo "✅ Готово! Сервер защищён и готов к работе."
