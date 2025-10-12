#!/bin/bash

set -e  # Прервать выполнение при любой ошибке

echo "🚀 Начинаю базовую настройку безопасности сервера..."

# 1. Обновление системы
echo "🔄 Обновляю систему..."
sudo apt update
sudo DEBIAN_FRONTEND=noninteractive apt upgrade -y
sudo DEBIAN_FRONTEND=noninteractive apt dist-upgrade -y
sudo apt autoremove -y

# 2. Автоматические обновления безопасности
echo "🛡️ Устанавливаю unattended-upgrades..."
sudo apt install -y unattended-upgrades
echo 'unattended-upgrades unattended-upgrades/enable_auto_updates boolean true' | sudo debconf-set-selections
sudo dpkg-reconfigure -f noninteractive unattended-upgrades

# 3. Защита от брутфорса
echo "🛡️ Устанавливаю fail2ban..."
sudo apt install -y fail2ban
sudo systemctl enable fail2ban
sudo systemctl start fail2ban

# 4. Антивирус/руткит сканеры
echo "🔍 Устанавливаю rkhunter и chkrootkit..."
sudo apt install -y rkhunter chkrootkit
sudo rkhunter --update
sudo rkhunter --propupd

# 5. Утилиты мониторинга
echo "📊 Устанавливаю htop, iotop, nethogs..."
sudo apt install -y htop iotop nethogs

echo "✅ Done!»