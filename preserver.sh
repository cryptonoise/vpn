#!/bin/bash

# Очистка консоли в начале
printf "\033c"

# Установка переменной для неинтерактивного режима apt
export DEBIAN_FRONTEND=noninteractive

printf "🚀  Начинаю базовую настройку безопасности сервера...\n\n"

# === Обновление системы ===
printf "🔄  Обновляю систему...\n"
echo "──────────────────────────────────────"

if ! apt-get update; then
    echo "❌ Ошибка: не удалось выполнить 'apt-get update'. Проверьте подключение к интернету и файл /etc/apt/sources.list."
    exit 1
fi

if ! apt-get upgrade -y \
    -o Dpkg::Options::="--force-confdef" \
    -o Dpkg::Options::="--force-confold"; then
    echo "❌ Ошибка при выполнении 'apt-get upgrade'."
    exit 1
fi

if ! apt-get dist-upgrade -y \
    -o Dpkg::Options::="--force-confdef" \
    -o Dpkg::Options::="--force-confold"; then
    echo "❌ Ошибка при выполнении 'apt-get dist-upgrade'."
    exit 1
fi

apt-get autoremove -y

echo "──────────────────────────────────────"
printf "✅  Система успешно обновлена!\n\n"

# Очистка экрана после обновления
printf "\033c"

# === Функция установки пакета, если отсутствует ===
install_if_missing() {
    local pkg="$1"
    if ! dpkg -s "$pkg" &>/dev/null; then
        printf "📦  Устанавливаю %s... " "$pkg"
        if apt-get install -y -qq "$pkg"; then
            printf "✅\n"
        else
            printf "❌\n"
            echo "⚠️  Не удалось установить пакет: $pkg"
        fi
    else
        printf "📦  Пакет %s уже установлен.\n" "$pkg"
    fi
}

# Установка необходимых пакетов
install_if_missing "unattended-upgrades"
install_if_missing "fail2ban"
install_if_missing "htop"
install_if_missing "iotop"
install_if_missing "nethogs"

# Запуск и включение fail2ban
if systemctl is-active --quiet fail2ban; then
    printf "🛡️  fail2ban уже запущен.\n"
else
    systemctl enable fail2ban --quiet
    systemctl start fail2ban --quiet
    printf "🛡️  fail2ban запущен и включён в автозагрузку.\n"
fi

# === Создание пользователя suser (если не существует) ===
if ! id -u suser &>/dev/null; then
    printf "👤  Создаю пользователя suser... "
    if useradd -m -s /bin/bash -G sudo suser; then
        printf "✅\n"
    else
        printf "❌\n"
        echo "⚠️  Не удалось создать пользователя suser."
    fi
else
    printf "👤  Пользователь suser уже существует.\n"
fi

# === Настройка SSH ===
SSH_CONFIG="/etc/ssh/sshd_config"
if [[ -f "$SSH_CONFIG" ]]; then
    printf "🔐  Настраиваю SSH... "
    sed -i 's/^#\?PermitRootLogin.*/PermitRootLogin no/' "$SSH_CONFIG"
    sed -i 's/^#\?PasswordAuthentication.*/PasswordAuthentication no/' "$SSH_CONFIG"
    sed -i 's/^#\?PubkeyAuthentication.*/PubkeyAuthentication yes/' "$SSH_CONFIG"
    if systemctl restart sshd; then
        printf "✅\n\n"
    else
        printf "❌\n"
        echo "⚠️  Не удалось перезапустить sshd.
