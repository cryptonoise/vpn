#!/bin/bash
set -e

# Очистка консоли (надёжно)
printf "\033c"

if [ -f /root/.server_secured ]; then
    printf "✅  Сервер уже защищён. Повторный запуск не требуется.\n"
    exit 0
fi

# === Универсальный спиннер (работает и без tty) ===
run_with_spinner() {
    local msg="$1"
    shift
    local cmd=("$@")
    local spin=('⠋' '⠙' '⠹' '⠸' '⠼' '⠴' '⠦' '⠧' '⠇' '⠏')

    printf "%-25s " "$msg"

    "${cmd[@]}" &
    local pid=$!
    local i=0

    while kill -0 "$pid" 2>/dev/null; do
        printf "\r%-25s %s " "$msg" "${spin[$((i++ % ${#spin[@]}))]}"
        sleep 0.1
    done

    wait "$pid"
    local code=$?

    if [ $code -eq 0 ]; then
        printf "\r%-25s ✅\n" "$msg"
    else
        printf "\r%-25s ❌\n" "$msg"
    fi
}

# === Проверка и скрытая установка пакета ===
install_if_missing() {
    local pkg="$1"
    local msg="$2"
    if dpkg -s "$pkg" &>/dev/null; then
        printf "%-25s ✅ уже установлено\n" "$msg"
    else
        run_with_spinner "$msg" bash -c "DEBIAN_FRONTEND=noninteractive apt install -y $pkg >/dev/null 2>&1"
    fi
}

printf "🚀  Начинаю базовую настройку безопасности сервера...\n\n"

# Обновление системы (скрыто)
run_with_spinner "🔄  Обновляю систему..." \
    bash -c "DEBIAN_FRONTEND=noninteractive apt update >/dev/null 2>&1 && apt upgrade -y >/dev/null 2>&1 && apt autoremove -y >/dev/null 2>&1"

# unattended-upgrades
if dpkg -s "unattended-upgrades" &>/dev/null; then
    printf "%-25s ✅ уже установлено\n" "🛡️  unattended-upgrades"
else
    run_with_spinner "🛡️  Устанавливаю unattended-upgrades..." \
        bash -c "DEBIAN_FRONTEND=noninteractive apt install -y unattended-upgrades >/dev/null 2>&1 && \
                 echo 'unattended-upgrades unattended-upgrades/enable_auto_updates boolean true' | debconf-set-selections && \
                 dpkg-reconfigure -f noninteractive unattended-upgrades >/dev/null 2>&1"
fi

# fail2ban
install_if_missing "fail2ban" "🚫  Устанавливаю fail2ban..."
systemctl enable fail2ban --quiet
systemctl start fail2ban --quiet

# htop, iotop, nethogs
for pkg in htop iotop nethogs; do
    install_if_missing "$pkg" "📊  Устанавливаю $pkg..."
done

touch /root/.server_secured
printf "\n✅  Готово! Сервер защищён и готов к работе.\n\n"

# === Таймер перезагрузки 5 секунд ===
echo "🔄  Перезагрузка через 5 секунд..."
for i in $(seq 5 -1 1); do
    printf "\r   %d " "$i"
    sleep 1
done
printf "\n"

reboot
