#!/bin/bash

# Очистка экрана
printf "\033c"

# Настройка неинтерактивного режима
export DEBIAN_FRONTEND=noninteractive
export APT_LISTCHANGES_FRONTEND=none

printf "🚀  Начинаю базовую настройку безопасности сервера...\n\n"

# === ФУНКЦИЯ: автоматическое восстановление dpkg ===
auto_fix_dpkg() {
    printf "🔧  Проверяю состояние dpkg... "
    if dpkg --audit &>/dev/null; then
        printf "все в порядке.\n"
    else
        printf "обнаружены незавершённые пакеты, исправляю...\n"
        if DEBIAN_FRONTEND=noninteractive dpkg --configure -a \
            -o Dpkg::Options::="--force-confdef" \
            -o Dpkg::Options::="--force-confold"; then
            printf "✅  dpkg успешно восстановлен.\n"
        else
            echo "❌  Критическая ошибка: не удалось автоматически восстановить dpkg."
            exit 1
        fi
    fi
}

# === ШАГ 1: Восстановление dpkg ДО обновления ===
auto_fix_dpkg

# === ШАГ 2: Обновление системы ===
printf "🔄  Обновляю систему...\n"
echo "──────────────────────────────────────"

if ! apt-get update -y; then
    echo "❌ Ошибка: apt-get update завершился неудачно."
    exit 1
fi

# Проверяем dpkg после update
auto_fix_dpkg

# Обновление пакетов
if ! apt-get upgrade -y \
    -o Dpkg::Options::="--force-confdef" \
    -o Dpkg::Options::="--force-confold"; then
    echo "❌ Ошибка при выполнении apt-get upgrade."
    exit 1
fi

if ! apt-get dist-upgrade -y \
    -o Dpkg::Options::="--force-confdef" \
    -o Dpkg::Options::="--force-confold"; then
    echo "❌ Ошибка при выполнении apt-get dist-upgrade."
    exit 1
fi

apt-get autoremove -y

echo "──────────────────────────────────────"
printf "✅  Система успешно обновлена!\n\n"

# Очистка экрана после обновления
printf "\033c"

# === Установка пакетов ===
install_if_missing() {
    local pkg="$1"
    if ! dpkg -s "$pkg" &>/dev/null; then
        printf "📦  Устанавливаю %s... " "$pkg"
        if apt-get install -y -qq \
            -o Dpkg::Options::="--force-confdef" \
            -o Dpkg::Options::="--force-confold" "$pkg" &>/dev/null; then
            printf "✅\n"
        else
            printf "❌ (ошибка установки)\n"
        fi
    else
        printf "📦  %s уже установлен.\n" "$pkg"
    fi
}

# Установка необходимых пакетов
for pkg in unattended-upgrades fail2ban htop iotop nethogs; do
    install_if_missing "$pkg"
done

# Настройка fail2ban
systemctl enable fail2ban --quiet
systemctl start fail2ban --quiet

# === Создание пользователя suser ===
if ! id -u suser &>/dev/null; then
    printf "👤  Создаю пользователя suser... "
    if useradd -m -s /bin/bash -G sudo suser; then
        printf "✅\n"
    else
        printf "❌\n"
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
        printf "❌ (не удалось перезапустить sshd)\n\n"
    fi
else
    echo "⚠️  Файл SSH-конфигурации не найден. Пропускаю настройку."
fi

printf "✅  Готово! Сервер защищён и готов к работе.\n\n"

# === Перезагрузка с возможностью отмены ===
echo "🔄  Перезагрузка через 5 секунд... (нажмите Enter, чтобы отменить)"
for i in $(seq 5 -1 1); do
    printf "\r   %d " "$i"
    if read -t 1 -n 1 key; then
        echo -e "\n⏹  Перезагрузка отменена пользователем."
        exit 0
    fi
done
printf "\n"

reboot
