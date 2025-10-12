#!/bin/bash

printf "\033c"
export DEBIAN_FRONTEND=noninteractive

printf "🚀  Начинаю базовую настройку безопасности сервера...\n\n"

# Функция для восстановления dpkg
fix_dpkg_if_needed() {
    if [ -d /var/lib/dpkg/updates ] && ls /var/lib/dpkg/updates/* >/dev/null 2>&1; then
        printf "🔧  Обнаружены незавершённые операции dpkg. Выполняю восстановление...\n"
        if ! dpkg --configure -a \
            -o Dpkg::Options::="--force-confdef" \
            -o Dpkg::Options::="--force-confold"; then
            echo "❌ Не удалось восстановить dpkg. Выполните вручную: dpkg --configure -a"
            exit 1
        fi
        printf "✅  Восстановление завершено.\n\n"
    fi
}

# === Обновление системы ===
printf "🔄  Обновляю систему...\n"
echo "──────────────────────────────────────"

apt-get update || { echo "❌ apt-get update failed"; exit 1; }

# Проверяем и исправляем dpkg ПЕРЕД upgrade
fix_dpkg_if_needed

apt-get upgrade -y \
    -o Dpkg::Options::="--force-confdef" \
    -o Dpkg::Options::="--force-confold" || { echo "❌ apt-get upgrade failed"; exit 1; }

apt-get dist-upgrade -y \
    -o Dpkg::Options::="--force-confdef" \
    -o Dpkg::Options::="--force-confold" || { echo "❌ apt-get dist-upgrade failed"; exit 1; }

apt-get autoremove -y

echo "──────────────────────────────────────"
printf "✅  Система успешно обновлена!\n\n"

# Очистка экрана
printf "\033c"

# === Далее — остальная часть скрипта ===

install_if_missing() {
    local pkg="$1"
    if ! dpkg -s "$pkg" &>/dev/null; then
        printf "📦  Устанавливаю %s... " "$pkg"
        apt-get install -y -qq "$pkg" && printf "✅\n" || printf "❌\n"
    fi
}

# Установка пакетов
for pkg in unattended-upgrades fail2ban htop iotop nethogs; do
    install_if_missing "$pkg"
done

# fail2ban
systemctl enable fail2ban --quiet
systemctl start fail2ban --quiet

# Пользователь suser
if ! id -u suser &>/dev/null; then
    printf "👤  Создаю пользователя suser... "
    useradd -m -s /bin/bash -G sudo suser && printf "✅\n" || printf "❌\n"
fi

# SSH
SSH_CONFIG="/etc/ssh/sshd_config"
if [[ -f "$SSH_CONFIG" ]]; then
    printf "🔐  Настраиваю SSH... "
    sed -i 's/^#\?PermitRootLogin.*/PermitRootLogin no/' "$SSH_CONFIG"
    sed -i 's/^#\?PasswordAuthentication.*/PasswordAuthentication no/' "$SSH_CONFIG"
    sed -i 's/^#\?PubkeyAuthentication.*/PubkeyAuthentication yes/' "$SSH_CONFIG"
    systemctl restart sshd && printf "✅\n\n" || printf "❌\n\n"
fi

printf "✅  Готово! Сервер защищён и готов к работе.\n\n"

# Перезагрузка с отменой
echo "🔄  Перезагрузка через 5 секунд... (нажмите Enter чтобы отменить)"
for i in $(seq 5 -1 1); do
    printf "\r   %d " "$i"
    read -t 1 -n 1 key && { echo -e "\n⏹  Перезагрузка отменена."; exit 0; }
done
printf "\n"
reboot
