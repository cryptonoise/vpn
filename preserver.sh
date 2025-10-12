#!/bin/bash

set -e

# Функция анимации (спиннер)
spinner() {
    local pid=$1
    local delay=0.1
    local spinstr='⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏'
    while [ "$(ps a | awk '{print $1}' | grep $pid)" ]; do
        local temp=${spinstr#?}
        printf " [%c]  " "$spinstr"
        local spinstr=$temp${spinstr%"$temp"}
        sleep $delay
        printf "\b\b\b\b\b\b"
    done
    printf " ✅ \n"
}

echo "🚀 Начинаю базовую настройку безопасности сервера..."
echo

# 1. Обновление системы
echo "🔄 Обновляю систему..."
sudo apt update >/dev/null 2>&1 &
spinner $!
sudo DEBIAN_FRONTEND=noninteractive apt upgrade -y >/dev/null 2>&1 &
spinner $!
sudo DEBIAN_FRONTEND=noninteractive apt dist-upgrade -y >/dev/null 2>&1 &
spinner $!
sudo apt autoremove -y >/dev/null 2>&1
echo

# 2. Автоматические обновления безопасности
echo "🛡️ Устанавливаю unattended-upgrades..."
sudo apt install -y unattended-upgrades >/dev/null 2>&1 &
spinner $!
echo 'unattended-upgrades unattended-upgrades/enable_auto_updates boolean true' | sudo debconf-set-selections
sudo dpkg-reconfigure -f noninteractive unattended-upgrades >/dev/null 2>&1
echo

# 3. Защита от брутфорса
echo "🛡️ Устанавливаю fail2ban..."
sudo apt install -y fail2ban >/dev/null 2>&1 &
spinner $!
sudo systemctl enable fail2ban --quiet
sudo systemctl start fail2ban --quiet
echo

# 4. Антивирус/руткит сканеры
echo "🔍 Устанавливаю rkhunter и chkrootkit..."
sudo apt install -y rkhunter chkrootkit >/dev/null 2>&1 &
spinner $!
sudo rkhunter --update --quiet >/dev/null 2>&1
sudo rkhunter --propupd --quiet >/dev/null 2>&1
echo

# 5. Утилиты мониторинга
echo "📊 Устанавливаю htop, iotop, nethogs..."
sudo apt install -y htop iotop nethogs >/dev/null 2>&1 &
spinner $!

echo
echo "✅ Готово!"
