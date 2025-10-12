#!/bin/bash

set -e

# === Проверка: уже настроен? ===
if [ -f /root/.server_secured ]; then
    echo "✅ Сервер уже защищён. Повторный запуск не требуется."
    exit 0
fi

echo "🚀 Начинаю базовую настройку безопасности сервера..."

# 1. Обновление системы
echo "🔄 Обновляю систему..."
sudo apt update >/dev/null 2>&1
sudo DEBIAN_FRONTEND=noninteractive apt upgrade -y >/dev/null 2>&1
sudo DEBIAN_FRONTEND=noninteractive apt dist-upgrade -y >/dev/null 2>&1
sudo apt autoremove -y >/dev/null 2>&1

# 2. Автоматические обновления безопасности
echo "🛡️ Устанавливаю unattended-upgrades..."
sudo apt install -y --no-install-recommends unattended-upgrades >/dev/null 2>&1
echo 'unattended-upgrades unattended-upgrades/enable_auto_updates boolean true' | sudo debconf-set-selections
sudo dpkg-reconfigure -f noninteractive unattended-upgrades >/dev/null 2>&1

# 3. Защита от брутфорса
echo "🛡️ Устанавливаю fail2ban..."
sudo apt install -y --no-install-recommends fail2ban >/dev/null 2>&1
sudo systemctl enable fail2ban --quiet
sudo systemctl start fail2ban --quiet

# 4. Антивирус/руткит сканеры
echo "🔍 Устанавливаю rkhunter и chkrootkit..."
sudo apt install -y --no-install-recommends rkhunter chkrootkit >/dev/null 2>&1
sudo rkhunter --update --quiet >/dev/null 2>&1
sudo rkhunter --propupd --quiet >/dev/null 2>&1

# 5. Утилиты мониторинга
echo "📊 Устанавливаю htop, iotop, nethogs..."
sudo apt install -y --no-install-recommends htop iotop nethogs >/dev/null 2>&1

# === Помечаем как настроенный ===
touch /root/.server_secured

echo "✅ Базовая безопасность сервера настроена!"
echo "💡 Рекомендуется:"
echo "   - Отключить вход по паролю в SSH"
echo "   - Настроить UFW (фаервол)"
echo "   - Убедиться, что Amnezia использует только нужные порты"
