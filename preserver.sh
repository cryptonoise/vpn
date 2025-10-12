#!/bin/bash

printf "\033c"
export DEBIAN_FRONTEND=noninteractive
export APT_LISTCHANGES_FRONTEND=none

printf "🚀  Начинаю базовую настройку безопасности сервера...\n\n"

# === Восстановление только при наличии проблем ===
if [ -d /var/lib/dpkg/updates ] && ls /var/lib/dpkg/updates/* >/dev/null 2>&1; then
    printf "🔧  Обнаружены следы прерванной установки. Выполняю восстановление...\n"
    rm -f /var/lib/dpkg/lock /var/lib/dpkg/lock-frontend
    rm -f /var/cache/apt/archives/lock /var/lib/apt/lists/lock
    DEBIAN_FRONTEND=noninteractive dpkg --configure -a --force-confdef --force-confold >/dev/null 2>&1 || true
    rm -f /var/lib/dpkg/updates/*
    dpkg --configure -a >/dev/null 2>&1 || true
    printf "✅  Восстановление завершено.\n\n"
fi

# === Обновление системы ===
printf "🔄  Обновляю систему...\n"
echo "──────────────────────────────────────"

apt-get update || { echo "❌ apt-get update failed"; exit 1; }
apt-get upgrade -y -o Dpkg::Options::="--force-confdef" -o Dpkg::Options::="--force-confold" || { echo "❌ upgrade failed"; exit 1; }
apt-get dist-upgrade -y -o Dpkg::Options::="--force-confdef" -o Dpkg::Options::="--force-confold" || { echo "❌ dist-upgrade failed"; exit 1; }
apt-get autoremove -y

echo "──────────────────────────────────────"
printf "✅  Система успешно обновлена!\n\n"

printf "\033c"

# === ФУНКЦИЯ УСТАНОВКИ (без лишнего вывода и с защитой от зависаний) ===
install_if_missing() {
    local pkg="$1"
    if ! dpkg -s "$pkg" &>/dev/null; then
        printf "📦  Устанавливаю %s... " "$pkg"
        if DEBIAN_FRONTEND=noninteractive \
           apt-get install -y --no-install-recommends \
           -o Dpkg::Options::="--force-confdef" \
           -o Dpkg::Options::="--force-confold" \
           "$pkg" &>/dev/null; then
            printf "✅\n"
        else
            printf "❌\n"
        fi
    fi
    # Если пакет уже установлен — ничего не выводим
}

# === Установка пакетов ===
for pkg in unattended-upgrades fail2ban htop iotop nethogs; do
    install_if_missing "$pkg"
done

# Настройка fail2ban
systemctl enable fail2ban --quiet
systemctl start fail2ban --quiet

# === Пользователь suser ===
if ! id -u suser &>/dev/null; then
    printf "👤  Создаю пользователя suser... "
    useradd -m -s /bin/bash -G sudo suser && printf "✅\n"
else
    printf "👤  Пользователь suser уже существует.\n"
fi

echo "suser:0suser1" | chpasswd
printf "🔑  Пароль для suser: 0suser1\n"

# === Настройка SSH ===
SSH_CONFIG="/etc/ssh/sshd_config"
if [[ -f "$SSH_CONFIG" ]]; then
    printf "🔐  Настраиваю SSH... "
    sed -i 's/^#\?PermitRootLogin.*/PermitRootLogin no/' "$SSH_CONFIG"
    sed -i 's/^#\?PubkeyAuthentication.*/PubkeyAuthentication yes/' "$SSH_CONFIG"
    sed -i 's/^#\?PasswordAuthentication.*/PasswordAuthentication yes/' "$SSH_CONFIG"
    systemctl restart sshd && printf "✅\n\n" || printf "❌\n\n"
else
    echo "⚠️  SSH config not found."
fi

printf "✅  Готово! Сервер настроен.\n"
printf "   • Пользователь: suser\n"
printf "   • Пароль: 0suser1\n"
printf "   • Root-доступ: отключён\n\n"

# === Перезагрузка ===
echo "🔄  Перезагрузка через 5 секунд... (нажмите Enter, чтобы отменить)"
for i in $(seq 5 -1 1); do
    printf "\r   %d " "$i"
    if read -t 1 -n 1 key; then
        echo -e "\n⏹  Перезагрузка отменена."
        exit 0
    fi
done
printf "\n"

reboot
