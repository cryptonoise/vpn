#!/bin/bash
set -e

# Очистка консоли
printf "\033c"

# === Выполнение команды с сообщением ===
run() {
    local msg="$1"
    shift
    printf "%-50s" "$msg"
    "$@"
    local code=$?
    if [ $code -eq 0 ]; then
        printf " ✅\n"
    else
        printf " ❌\n"
    fi
}

# === Установка пакета если отсутствует ===
install_if_missing() {
    local pkg="$1"
    if ! dpkg -s "$pkg" &>/dev/null; then
        run "📦  Устанавливаю $pkg..." bash -c "DEBIAN_FRONTEND=noninteractive apt install -y $pkg >/dev/null 2>&1"
    fi
}

printf "🚀  Начинаю базовую настройку безопасности сервера...\n\n"

# Быстрое обновление системы без интерактивности
run "🔄  Обновляю систему..." bash -c "
DEBIAN_FRONTEND=noninteractive apt update >/dev/null 2>&1 &&
DEBIAN_FRONTEND=noninteractive apt upgrade -y -o Dpkg::Options::='--force-confdef' -o Dpkg::Options::='--force-confold' >/dev/null 2>&1 &&
DEBIAN_FRONTEND=noninteractive apt dist-upgrade -y -o Dpkg::Options::='--force-confdef' -o Dpkg::Options::='--force-confold' >/dev/null 2>&1 &&
DEBIAN_FRONTEND=noninteractive apt autoremove -y >/dev/null 2>&1
"

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
    run "👤  Создаю пользователя suser..." bash -c "useradd -m -s /bin/bash -G sudo suser"
fi

# Настройка SSH
SSH_CONFIG="/etc/ssh/sshd_config"
run "🔐  Настройка SSH для безопасности..." bash -c "
    sed -i 's/^#\?PermitRootLogin.*/PermitRootLogin no/' $SSH_CONFIG
    sed -i 's/^#\?PasswordAuthentication.*/PasswordAuthentication no/' $SSH_CONFIG
    sed -i 's/^#\?PubkeyAuthentication.*/PubkeyAuthentication yes/' $SSH_CONFIG
    systemctl restart sshd
"

printf "\n✅  Готово! Сервер защищён и готов к работе.\n\n"

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
