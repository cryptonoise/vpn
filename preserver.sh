#!/bin/bash
set -e

# Очистка консоли
printf "\033c"

# === Спиннер для фоновых задач ===
run_with_spinner() {
    local msg="$1"
    shift
    local cmd=("$@")
    local spin=('⠋' '⠙' '⠹' '⠸' '⠼' '⠴' '⠦' '⠧' '⠇' '⠏')

    printf "%-30s " "$msg"

    "${cmd[@]}" >/dev/null 2>&1 &
    local pid=$!
    local i=0

    while kill -0 "$pid" 2>/dev/null; do
        printf "\r%-30s %s " "$msg" "${spin[$((i++ % ${#spin[@]}))]}"
        sleep 0.1
    done

    wait "$pid"
    local code=$?

    if [ $code -eq 0 ]; then
        printf "\r%-30s ✅\n" "$msg"
    else
        printf "\r%-30s ❌\n" "$msg"
    fi
}

# === Установка пакета если отсутствует ===
install_if_missing() {
    local pkg="$1"
    if ! dpkg -s "$pkg" &>/dev/null; then
        run_with_spinner "📦  Устанавливаю $pkg..." bash -c "sudo apt-get install -y -qq $pkg"
    fi
}

printf "🚀  Начинаю базовую настройку безопасности сервера...\n\n"

# === Обновление системы без спиннера (не в фоне!) ===
echo "🔄  Обновляю систему..."
export DEBIAN_FRONTEND=noninteractive
sudo apt-get update -qq
sudo apt-get upgrade -y -qq
sudo apt-get dist-upgrade -y -qq
sudo apt-get autoremove -y -qq
echo "✅  Система обновлена."

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

# === Создание пользователя suser ===
if ! id -u suser &>/dev/null; then
    run_with_spinner "👤  Создаю пользователя suser..." bash -c "sudo useradd -m -s /bin/bash -G sudo suser"
fi

# Настройка SSH
SSH_CONFIG="/etc/ssh/sshd_config"
run_with_spinner "🔐  Настройка SSH для безопасности..." bash -c "
    sudo sed -i 's/^#\?PermitRootLogin.*/PermitRootLogin no/' $SSH_CONFIG
    sudo sed -i 's/^#\?PasswordAuthentication.*/PasswordAuthentication no/' $SSH_CONFIG
    sudo sed -i 's/^#\?PubkeyAuthentication.*/PubkeyAuthentication yes/' $SSH_CONFIG
    sudo systemctl restart sshd
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
