#!/bin/bash
set -e

# Очистка консоли
printf "\033c"

# Установка переменной для неинтерактивного apt
export DEBIAN_FRONTEND=noninteractive

printf "🚀  Начинаю базовую настройку безопасности сервера...\n\n"

# === Обновление системы ===
printf "🔄  Обновляю систему...\n"
echo "──────────────────────────────────────"

# Обновление списка пакетов
apt-get update

# Обновление установленных пакетов с автоматическим выбором конфигураций
apt-get upgrade -y \
    -o Dpkg::Options::="--force-confdef" \
    -o Dpkg::Options::="--force-confold"

# Полное обновление (включая ядро и зависимости)
apt-get dist-upgrade -y \
    -o Dpkg::Options::="--force-confdef" \
    -o Dpkg::Options::="--force-confold"

# Удаление ненужных пакетов
apt-get autoremove -y

echo "──────────────────────────────────────"
printf "✅  Система успешно обновлена!\n\n"

# Очистка экрана после обновления
printf "\033c"

# === Функция установки пакета если отсутствует ===
install_if_missing() {
    local pkg="$1"
    if ! dpkg -s "$pkg" &>/dev/null; then
        printf "📦  Устанавливаю %s... " "$pkg"
        apt-get install -y -qq "$pkg"
        printf "✅\n"
    fi
}

# unattended-upgrades
install_if_missing "unattended-upgrades"

# fail2ban
install_if_missing "fail2ban"
systemctl enable fail2ban --quiet
systemctl start fail2ban --quiet

# htop, iotop, nethogs
for pkg in htop iotop nethogs; do
    install_if_missing "$pkg"
done

# === Автоматическое создание пользователя suser и отключение root ===
if ! id -u suser &>/dev/null; then
    printf "👤  Создаю пользователя suser... "
    useradd -m -s /bin/bash -G sudo suser
    printf "✅\n"
fi

# === Настройка SSH для безопасности ===
SSH_CONFIG="/etc/ssh/sshd_config"
printf "🔐  Настраиваю SSH... "
sed -i 's/^#\?PermitRootLogin.*/PermitRootLogin no/' "$SSH_CONFIG"
sed -i 's/^#\?PasswordAuthentication.*/PasswordAuthentication no/' "$SSH_CONFIG"
sed -i 's/^#\?PubkeyAuthentication.*/PubkeyAuthentication yes/' "$SSH_CONFIG"
systemctl restart sshd
printf "✅\n\n"

printf "✅  Готово! Сервер защищён и готов к работе.\n\n"

# === Таймер перезагрузки 5 секунд с возможностью отмены по Enter ===
echo "🔄  Перезагрузка через 5 секунд... (нажмите Enter чтобы отменить)"
for i in $(seq 5 -1 1); do
    printf "\r   %d " "$i"
    read -t 1 -n 1 key
    if [[ $key == "" ]]; then
        echo -e "\n⏹  Перезагрузка отменена пользователем."
        exit 0
    fi
done
printf "\n"

reboot
