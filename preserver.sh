#!/bin/bash

# Очистка консоли
printf "\033c"

# Установка переменной для неинтерактивного apt
export DEBIAN_FRONTEND=noninteractive

printf "🚀  Начинаю базовую настройку безопасности сервера...\n\n"

# === Восстановление после прерванного dpkg (если нужно) ===
if [ -f /var/lib/dpkg/lock ] || [ -f /var/lib/dpkg/lock-frontend ] || \
   find /var/lib/dpkg/updates -name "*" 2>/dev/null | grep -q .; then
    printf "🔧  Обнаружены следы прерванной установки пакетов. Выполняю восстановление...\n"
    if dpkg --configure -a; then
        printf "✅  Восстановление завершено.\n\n"
    else
        echo "❌ Не удалось восстановить состояние dpkg. Исправьте вручную и повторите запуск."
        exit 1
    fi
fi

# === Обновление системы ===
printf "🔄  Обновляю систему...\n"
echo "──────────────────────────────────────"

if ! apt-get update; then
    echo "❌ Ошибка: не удалось выполнить 'apt-get update'."
    exit 1
fi

if ! apt-get upgrade -y \
    -o Dpkg::Options::="--force-confdef" \
    -o Dpkg::Options::="--force-confold"; then
    echo "❌ Ошибка при выполнении 'apt-get upgrade'."
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
