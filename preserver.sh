#!/bin/bash
set -e

echo -e "\n🚀 Начинаю базовую настройку безопасности сервера...\n"

# Обновление системы
echo -ne "🔄  Обновляю систему...                 "
apt update -qq && apt upgrade -y -qq
echo "✅"

# Установка автоматических обновлений
echo -ne "🛡️  Устанавливаю unattended-upgrades... "
apt install -y -qq unattended-upgrades
systemctl enable unattended-upgrades >/dev/null 2>&1
echo "✅"

# Установка Fail2Ban
echo -ne "🚫  Устанавливаю fail2ban...            "
apt install -y -qq fail2ban
systemctl enable fail2ban >/dev/null 2>&1
echo "✅"

# Установка rkhunter и chkrootkit без сканирования
echo -ne "🔍  Устанавливаю rkhunter и chkrootkit... "
apt install -y -qq rkhunter chkrootkit
rkhunter --update --quiet
rkhunter --propupd --quiet
echo "✅"

# Минимальные настройки SSH
echo -ne "🔒  Проверяю настройки SSH...           "
SSHD_CONFIG="/etc/ssh/sshd_config"
sed -i 's/#*PermitRootLogin.*/PermitRootLogin no/' "$SSHD_CONFIG"
sed -i 's/#*PasswordAuthentication.*/PasswordAuthentication no/' "$SSHD_CONFIG"
systemctl restart ssh >/dev/null 2>&1
echo "✅"

# Очистка системы
echo -ne "🧹  Очищаю ненужные пакеты...           "
apt autoremove -y -qq && apt clean -qq
echo "✅"

echo -e "\n✨ Базовая настройка безопасности завершена успешно!\n"
