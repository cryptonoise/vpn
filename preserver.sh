#!/bin/bash

# Очистка экрана
printf "\033c"

# Настройка неинтерактивного режима
export DEBIAN_FRONTEND=noninteractive
export APT_LISTCHANGES_FRONTEND=none

printf "🚀  Начинаю базовую настройку безопасности сервера...\n\n"

# === ВОССТАНОВЛЕНИЕ ТОЛЬКО ЕСЛИ ЕСТЬ ПРОБЛЕМЫ ===
if [ -d /var/lib/dpkg/updates ] && ls /var/lib/dpkg/updates/* >/dev/null 2>&1; then
    printf "🔧  Обнаружены следы прерванной установки. Выполняю восстановление...\n"
    rm -f /var/lib/dpkg/lock /var/lib/dpkg/lock-frontend
    rm -f /var/cache/apt/archives/lock /var/lib/apt/lists/lock
    DEBIAN_FRONTEND=noninteractive dpkg --configure -a \
        --force-confdef --force-confold >/dev/null 2>&1 || true
    rm -f /var/lib/dpkg/updates/*
    dpkg --configure -a >/dev/null 2>&1 || true
    printf "✅  Восстановление завершено.\n\n"
fi

# === ОБНОВЛЕНИЕ СИСТЕМЫ ===
printf "🔄  Обновляю систему...\n"
echo "──────────────────────────────────────"

apt-get update || { echo "❌ Ошибка: apt-get update завершился неудачно."; exit 1; }

apt-get upgrade -y \
    -o Dpkg::Options::="--force-confdef" \
    -o Dpkg::Options::="--force-confold" || { echo "❌ Ошибка при выполнении apt-get upgrade."; exit 1; }

apt-get dist-upgrade -y \
    -o Dpkg::Options::="--force-confdef" \
    -o Dpkg::Options::="--force-confold" || { echo "❌ Ошибка при выполнении apt-get dist-upgrade."; exit 1; }

apt-get autoremove -y

echo "──────────────────────────────────────"
printf "✅  Система успешно обновлена!\n\n"

# Очистка экрана после обновления
printf "\033c"

# === ФУНКЦИЯ: УСТАНОВКА ПАКЕТА ЕСЛИ ОТСУТСТВУЕТ ===
install_if_missing() {
    local pkg="$1"
    if ! dpkg -s "$pkg" &>/dev/null; then
        printf "📦  Устанавливаю %s... " "$pkg"
        if apt-get install -y -qq \
            -o Dpkg::Options::="--force-confdef" \
            -o Dpkg::Options::="--force-confold" "$pkg" &>/dev/null; then
            printf "✅\n"
        else
            printf "❌\n"
        fi
    else
        printf "📦  Пакет %s уже установлен.\n" "$pkg"
    fi
}

# === УСТАНОВКА НЕОБХОДИМЫХ ПАКЕТОВ ===
for pkg in unattended-upgrades fail2ban htop iotop nethogs; do
    install_if_missing "$pkg"
done

# Настройка fail2ban
systemctl enable fail2ban --quiet
systemctl start fail2ban --quiet

# === СОЗДАНИЕ ПОЛЬЗОВАТЕЛЯ suser ===
if ! id -u suser &>/dev/null; then
    printf "👤  Создаю пользователя suser... "
    useradd -m -s /bin/bash -G sudo suser && printf "✅\n"
else
    printf "👤  Пользователь suser уже существует.\n"
fi

# Установка/обновление пароля
echo "suser:0suser1" | chpasswd
printf "🔑  Пароль для suser: 0suser1\n"

# === НАСТРОЙКА SSH ===
SSH_CONFIG="/etc/ssh/sshd_config"
if [[ -f "$SSH_CONFIG" ]]; then
    printf "🔐  Настраиваю SSH... "

    # Отключить root-доступ полностью
    sed -i 's/^#\?PermitRootLogin.*/PermitRootLogin no/' "$SSH_CONFIG"
    
    # Включить аутентификацию по ключу (если ключ есть — работает)
    sed -i 's/^#\?PubkeyAuthentication.*/PubkeyAuthentication yes/' "$SSH_CONFIG"
    
    # Разрешить вход по паролю (для suser и других пользователей с паролем)
    sed -i 's/^#\?PasswordAuthentication.*/PasswordAuthentication yes/' "$SSH_CONFIG"

    # Перезапуск SSH
    if systemctl restart sshd; then
        printf "✅\n\n"
    else
        printf "❌ (не удалось перезапустить sshd)\n\n"
    fi
else
    echo "⚠️  Файл $SSH_CONFIG не найден. Пропускаю настройку SSH."
fi

printf "✅  Готово! Сервер защищён и готов к работе.\n"
printf "   • Пользователь: suser\n"
printf "   • Пароль: 0suser1\n"
printf "   • Вход по SSH-ключу: разрешён (если ~/.ssh/authorized_keys существует)\n"
printf "   • Root-доступ: отключён\n\n"

# === ПЕРЕЗАГРУЗКА С ОТМЕНОЙ ===
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
