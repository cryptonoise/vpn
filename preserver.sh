#!/bin/bash

printf "\033c"
export DEBIAN_FRONTEND=noninteractive

printf "🚀  Начинаю базовую настройку безопасности сервера...\n\n"

# === Автоматическое восстановление dpkg при необходимости ===
if ls /var/lib/dpkg/updates/* >/dev/null 2>&1; then
    printf "🔧  Обнаружены незавершённые операции dpkg. Выполняю 'dpkg --configure -a'...\n"
    if ! dpkg --configure -a; then
        echo "❌ Не удалось восстановить систему. Выполните вручную: dpkg --configure -a"
        exit 1
    fi
    printf "✅  Состояние dpkg восстановлено.\n\n"
fi

# === Обновление системы ===
printf "🔄  Обновляю систему...\n"
echo "──────────────────────────────────────"

apt-get update || { echo "❌ apt-get update failed"; exit 1; }
apt-get upgrade -y -o Dpkg::Options::="--force-confdef" -o Dpkg::Options::="--force-confold" || { echo "❌ apt-get upgrade failed"; exit 1; }
apt-get dist-upgrade -y -o Dpkg::Options::="--force-confdef" -o Dpkg::Options::="--force-confold" || { echo "❌ apt-get dist-upgrade failed"; exit 1; }
apt-get autoremove -y

echo "──────────────────────────────────────"
printf "✅  Система успешно обновлена!\n\n"

printf "\033c"

# ... остальная часть скрипта (установка пакетов, настройка SSH и т.д.) ...
# (можно взять из предыдущего полного скрипта)
