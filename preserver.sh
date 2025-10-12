#!/bin/bash
set -e

# Очистка консоли
printf "\033c"

if [ -f /root/.server_secured ]; then
    printf "✅  Сервер уже защищён. Повторный запуск не требуется.\n"
    exit 0
fi

# === Спиннер обычный ===
run_with_spinner() {
    local msg="$1"
    shift
    local cmd=("$@")
    local spin=('⠋' '⠙' '⠹' '⠸' '⠼' '⠴' '⠦' '⠧' '⠇' '⠏')

    printf "%-35s " "$msg"

    "${cmd[@]}" >/dev/null 2>&1 &
    local pid=$!
    local i=0

    while kill -0 "$pid" 2>/dev/null; do
        printf "\r%-35s %s " "$msg" "${spin[$((i++ % ${#spin[@]}))]}"
        sleep 0.1
    done

    wait "$pid"
    local code=$?

    if [ $code -eq 0 ]; then
        printf "\r%-35s ✅\n" "$msg"
    else
        printf "\r%-35s ❌\n" "$msg"
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
update_with_progress() {
    # Получаем количество пакетов для обновления через симуляцию
    local total=$(apt-get -s upgrade | grep -P '^\d+ upgraded' | awk '{print $1}')
    
    if [ -z "$total" ] || [ "$total" -eq 0 ]; then
        run_with_spinner "🔄  Обновляю систему..." bash -c "apt upgrade -y >/dev/null 2>&1 && apt autoremove -y >/dev/null 2>&1"
        return
    fi

    local count=0
    local spin=('⠋' '⠙' '⠹' '⠸' '⠼' '⠴' '⠦' '⠧' '⠇' '⠏')

    # Запускаем реальное обновление в фоне
    apt upgrade -y >/tmp/apt_output.log 2>&1 &
    local pid=$!

    while kill -0 $pid 2>/dev/null; do
        if [ -f /tmp/apt_output.log ]; then
            # Считаем установленные пакеты
            count=$(grep -c 'Setting up' /tmp/apt_output.log)
        fi
        printf "\r%-35s %s %d/%d" "🔄  Обновляю систему..." "${spin[$((count % ${#spin[@]}))]}" "$count" "$total"
        sleep 0.3
    done

    wait $pid
    printf "\r%-35s ✅\n" "🔄  Обновление системы завершено"
    rm -f /tmp/apt_output.log
}

printf "🚀  Начинаю базовую настройку безопасности сервера...\n\n"

# Обновление системы с прогрессом пакетов
update_with_progress

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
