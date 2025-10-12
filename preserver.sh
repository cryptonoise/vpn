#!/bin/bash
set -e

# Очистка консоли
printf "\033c"

# === Спиннер ===
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
        run_with_spinner "📦  Устанавливаю $pkg..." bash -c "apt install -y $pkg >/dev/null 2>&1"
    fi
}

printf "🚀  Начинаю базовую настройку безопасности сервера...\n\n"

# === Принудительно завершаем все процессы apt и снимаем блокировки ===
run_with_spinner "🛠  Убираю блокировки apt..." bash -c "
    pkill -9 -f apt || true
    rm -f /var/lib/dpkg/lock-frontend /var/lib/dpkg/lock /var/cache/apt/archives/lock
    dpkg --configure -a
"

# Быстрое обновление системы (скрыто, без зависаний)
run_with_spinner "🔄  Обновляю систему..." bash -c "
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get upgrade -y -o Dpkg::Options::='--force-confdef' -o Dpkg::Options::='--force-confold' -qq
apt-get dist-upgrade -y -o Dpkg::Options::='--force-confdef' -o Dpkg::Options::='--force-confold' -qq
apt-get autoremove -y -qq
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
    run_with_spinner "👤  Создаю пользователя suser..." bash -c "useradd -m -s /bin/bash -G sudo suser"
fi

# Настройка SSH
SSH_CONFIG="/etc/ssh/sshd_config"
run_with_spinner "🔐  Настройка SSH для безопасности..." bash -c "
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
