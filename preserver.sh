#!/bin/bash
set -e

if [ -f /root/.server_secured ]; then
    printf "✅ Сервер уже защищён. Повторный запуск не требуется.\n"
    exit 0
fi

# === Универсальный спиннер с выравниванием ===
run_with_spinner() {
    local msg="$1"
    shift
    local cmd=("$@")
    local spin=('⠋' '⠙' '⠹' '⠸' '⠼' '⠴' '⠦' '⠧' '⠇' '⠏')
    local width=55

    printf "%-60s" "$msg"

    "${cmd[@]}" >/dev/null 2>&1 &
    local pid=$!
    local i=0

    while kill -0 "$pid" 2>/dev/null; do
        printf "\r%-60s%s" "$msg" "${spin[$((i++ % ${#spin[@]}))]}"
        sleep 0.1
    done

    wait "$pid"
    local code=$?
    if [ $code -eq 0 ]; then
        printf "\r%-60s✅\n" "$msg"
    else
        printf "\r%-60s❌\n" "$msg"
    fi
}

printf "🚀 Начинаю базовую настройку безопасности сервера...\n\n"

run_with_spinner "🔄  Обновляю систему..." \
    bash -c "apt update -qq && DEBIAN_FRONTEND=noninteractive apt upgrade -y -qq && apt autoremove -y -qq"

run_with_spinner "🛡️  Устанавливаю unattended-upgrades..." \
    bash -c "apt install -y -qq unattended-upgrades && \
             echo 'unattended-upgrades unattended-upgrades/enable_auto_updates boolean true' | debconf-set-selections && \
             dpkg-reconfigure -f noninteractive unattended-upgrades"

run_with_spinner "🚫  Устанавливаю fail2ban..." \
    bash -c "apt install -y -qq fail2ban && systemctl enable fail2ban --quiet && systemctl start fail2ban --quiet"

run_with_spinner "🔍  Устанавливаю rkhunter и chkrootkit..." \
    bash -c "apt install -y -qq rkhunter chkrootkit && rkhunter --update --quiet && rkhunter --propupd --quiet"

run_with_spinner "🔒  Настраиваю SSH..." \
    bash -c "sed -i 's/#*PermitRootLogin.*/PermitRootLogin no/' /etc/ssh/sshd_config && \
             sed -i 's/#*PasswordAuthentication.*/PasswordAuthentication no/' /etc/ssh/sshd_config && \
             systemctl restart ssh >/dev/null 2>&1"

run_with_spinner "🧹  Очищаю ненужные пакеты..." \
    bash -c "apt autoremove -y -qq && apt clean -qq"

touch /root/.server_secured

printf "\n✅ Готово! Сервер защищён и готов к работе.\n"
