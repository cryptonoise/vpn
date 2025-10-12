#!/bin/bash
set -e

# Очистка консоли
printf "\033c"

if [ -f /root/.server_secured ]; then
    printf "✅  Сервер уже защищён. Повторный запуск не требуется.\n"
    exit 0
fi

# === Спиннер ===
run_with_spinner() {
    local msg="$1"
    shift
    local cmd=("$@")
    local spin=('⠋' '⠙' '⠹' '⠸' '⠼' '⠴' '⠦' '⠧' '⠇' '⠏')

    printf "%-50s " "$msg"

    "${cmd[@]}" >/dev/null 2>&1 &
    local pid=$!
    local i=0

    while kill -0 "$pid" 2>/dev/null; do
        printf "\r%-50s %s " "$msg" "${spin[$((i++ % ${#spin[@]}))]}"
        sleep 0.1
    done

    wait "$pid"
    local code=$?

    if [ $code -eq 0 ]; then
        printf "\r%-50s ✅\n" "$msg"
    else
        printf "\r%-50s ❌\n" "$msg"
    fi
}

# === Установка пакета если отсутствует ===
install_if_missing() {
    local pkg="$1"
    if ! dpkg -s "$pkg" &>/dev/null; then
        run_with_spinner "📦  Устанавливаю $pkg..." bash -c "DEBIAN_FRONTEND=noninteractive apt install -y $pkg >/dev/null 2>&1"
    fi
}

# === Обновление системы с прогрессом пакетов ===
run_system_update() {
    # Получаем список обновляемых пакетов
    mapfile -t PKGS < <(apt list --upgradable 2>/dev/null | tail -n +2 | cut -d/ -f1)
    TOTAL=${#PKGS[@]}

    if [ "$TOTAL" -eq 0 ]; then
        run_with_spinner "🔄  Обновляю систему" bash -c "DEBIAN_FRONTEND=noninteractive apt upgrade -y >/dev/null 2>&1"
        return
    fi

    for i in "${!PKGS[@]}"; do
        pkg="${PKGS[$i]}"
        run_with_spinner "🔄  Обновляю пакет [$((i+1))/$TOTAL] $pkg" bash -c "DEBIAN_FRONTEND=noninteractive apt install -y $pkg >/dev/null 2>&1"
    done
}

printf "🚀  Начинаю базовую настройку безопасности сервера...\n\n"

# Обновление системы
run_system_update

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
if ! grep -q "^PermitRootLogin no" $SSH_CONFIG; then
    run_with_spinner "🔐  Настройка SSH для безопасности..." bash -c "
        sed -i 's/^#\?PermitRootLogin.*/PermitRootLogin no/' $SSH_CONFIG
        sed -i 's/^#\?PasswordAuthentication.*/PasswordAuthentication no/' $SSH_CONFIG
        sed -i 's/^#\?PubkeyAuthentication.*/PubkeyAuthentication yes/' $SSH_CONFIG
        systemctl restart sshd
    "
fi

# Отмечаем сервер как защищённый
touch /root/.server_secured
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
