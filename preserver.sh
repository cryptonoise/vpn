#!/bin/bash

set -e

# Проверка: уже настроен?
if [ -f /root/.server_secured ]; then
    echo "✅ Сервер уже защищён. Повторный запуск не требуется."
    exit 0
fi

echo "🚀 Начинаю базовую настройку безопасности сервера..."
echo

# Обновление системы
echo "🔄 Обновляю систему..."
apt update -qq >/dev/null 2>&1
DEBIAN_FRONTEND=noninteractive apt upgrade -y -qq >/dev/null 2>&1
DEBIAN_FRONTEND=noninteractive apt dist-upgrade -y -qq >/dev/null 2>&1
apt autoremove -y -qq >/dev/null 2>&1

# Автоматические обновления
echo "🛡️ Устанавливаю unattended-upgrades..."
apt install -y -qq --no-install-recommends unattended-upgrades >/dev/null 2>&1
echo 'unattended-upgrades unattended-upgrades/enable_auto_updates boolean true' | debconf-set-selections
dpkg-reconfigure -f noninteractive unattended-upgrades >/dev/null 2>&1

# Защита от брутфорса
echo "🚫 Устанавливаю fail2ban..."
apt install -y -qq --no-install-recommends fail2ban >/dev/null 2>&1
systemctl enable fail2ban --quiet
systemctl start fail2ban --quiet

# Утилиты мониторинга
echo "📊 Устанавливаю htop, iotop, nethogs..."
apt install -y -qq --no-install-recommends htop iotop nethogs >/dev/null 2>&1

# Помечаем как настроенный
touch /root/.server_secured

echo
echo "✅ Готово! Сервер защищён и готов к работе."
echo "💡 Рекомендуется:"
echo "   • Отключить вход по паролю в SSH"
echo "   • Настроить UFW (фаервол)"
echo "   • Разрешить только нужные порты AmneziaVPN"
