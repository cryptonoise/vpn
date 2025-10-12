#!/bin/bash

set -e

# Спиннер
run_with_spinner() {
    local msg="$1"
    local cmd="$2"

    echo -n "$msg "
    local pid
    eval "$cmd" >/dev/null 2>&1 &
    pid=$!

    local spinstr='⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏'
    local i=0
    while kill -0 $pid 2>/dev/null; do
        local idx=$((i % ${#spinstr}))
        local char="${spinstr:$idx:1}"
        printf "\b\b\b\b\b\b\b\b\b\b\b\b\b\b\b%10s" "$char"
        sleep 0.1
        ((i++))
    done

    wait $pid
    printf "\b\b\b\b\b\b\b\b\b\b\b\b\b\b\b%10s\n" "✅"
}

echo "🚀 Начинаю базовую настройку безопасности сервера..."
echo

# 1. Обновление системы
run_with_spinner "🔄 Обновляю систему..." \
    "sudo apt update && sudo DEBIAN_FRONTEND=noninteractive apt upgrade -y && sudo DEBIAN_FRONTEND=noninteractive apt dist-upgrade -y && sudo apt autoremove -y"

# 2. Автоматические обновления безопасности
run_with_spinner "🛡️ Устанавливаю unattended-upgrades..." \
    "sudo apt install -y unattended-upgrades && echo 'unattended-upgrades unattended-upgrades/enable_auto_updates boolean true' | sudo debconf-set-selections && sudo dpkg-reconfigure -f noninteractive unattended-upgrades"

# 3. Защита от брутфорса
run_with_spinner "🛡️ Устанавливаю fail2ban..." \
    "sudo apt install -y fail2ban && sudo systemctl enable fail2ban --quiet && sudo systemctl start fail2ban --quiet"

# 4. Антивирус/руткит сканеры
run_with_spinner "🔍 Устанавливаю rkhunter и chkrootkit..." \
    "sudo apt install -y rkhunter chkrootkit && sudo rkhunter --update --quiet && sudo rkhunter --propupd --quiet"

# 5. Утилиты мониторинга
run_with_spinner "📊 Устанавливаю htop, iotop, nethogs..." \
    "sudo apt install -y htop iotop nethogs"


echo
echo "✅ Готово!"
