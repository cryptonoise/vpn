#!/bin/bash

# Очистка экрана
printf "\033c"

# Настройка неинтерактивного режима
export DEBIAN_FRONTEND=noninteractive
export APT_LISTCHANGES_FRONTEND=none

printf "🚀  Начинаю базовую настройку безопасности сервера...\n\n"

# === ГАРАНТИРОВАННОЕ ВОССТАНОВЛЕНИЕ СОСТОЯНИЯ ПАКЕТОВ ===
printf "🔧  Гарантированное восстановление состояния пакетов...\n"

# Удаляем lock-файлы (на всякий случай)
rm -f /var/lib/dpkg/lock /var/lib/dpkg/lock-frontend
rm -f /var/cache/apt/archives/lock /var/lib/apt/lists/lock

# Принудительная настройка всех пакетов с подавлением запросов
DEBIAN_FRONTEND=noninteractive dpkg --configure -a \
  --force-confdef --force-confold --force-confnew >/dev/null 2>&1 || true

# 🔥 КЛЮЧЕВОЙ ШАГ: удаляем остаточные файлы, вызывающие ошибку "dpkg was interrupted"
if [ -d /var/lib/dpkg/updates ] && ls /var/lib/dpkg/updates/* >/dev/null 2>&1; then
    rm -f /var/lib/dpkg/updates/*
    printf "🗑️  Очистка /var/lib/dpkg/updates выполнена.\n"
fi

# Финальная попытка завершить настройку
dpkg --configure -a >/dev/null 2>&1 || true

printf "✅  Состояние пакетов стабилизировано.\n\n"

# === ОБНОВЛЕНИЕ СИСТЕМЫ ===
printf "🔄  Обновляю систему...\n"
echo "──────────────────────────────────────"

# Обновление списков пакетов
if ! apt-get update; then
    echo "❌ Ошибка: не удалось обновить списки пакетов (apt-get update)."
    exit 1
fi

# Повторная очистка перед upgrade (на случай, если update что-то создал)
if [ -d /var/lib/dpkg/updates ] && ls /var/lib/dpkg/updates/* >/dev/null 2>&1; then
    rm -f /var/lib/dpkg/updates/*
fi

# Обновление пакетов
if ! apt-get upgrade -y \
    -o Dpkg::Options::="--force-confdef" \
    -o Dpkg::Options::="--force-confold"; then
    echo "❌ Ошибка при выполнении apt-get upgrade."
    exit 1
fi

# Полное обновление
if ! apt-get dist-upgrade -y \
    -o Dpkg::Options::="--force-confdef" \
    -o Dpkg::Options::="--force-confold"; then
    echo "❌ Ошибка при выполнении apt-get dist-upgrade."
    exit 1
fi

# Удаление ненужных пакетов
apt-get autoremove -y

echo "──────────────────────────────────────"
printf "✅  Система успешно обновлена!\n\n"

# Очистка экрана после обновления
printf "\033c"

# === ФУНКЦИЯ: установка пакета, если отсутствует ===
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

# Настройка и запуск fail2ban
systemctl enable fail2ban --quiet
systemctl start fail2ban --quiet

# === СОЗДАНИЕ ПОЛЬЗОВАТЕЛЯ suser ===
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

# === НАСТРОЙКА SSH ===
SSH_CONFIG="/etc/ssh/sshd_config"
if [[ -f "$SSH_CONFIG" ]]; then
    printf "🔐  Настраиваю SSH... "
    sed -i 's/^#\?PermitRootLogin.*/PermitRootLogin no/' "$SSH_CONFIG"
    sed -i 's/^#\?PasswordAuthentication.*/PasswordAuthentication no/' "$SSH_CONFIG"
    sed -i 's/^#\?PubkeyAuthentication.*/PubkeyAuthentication yes/' "$SSH_CONFIG"
    if systemctl restart sshd; then
        printf "✅\n\n"
    else
        printf "❌\n\n"
    fi
else
    echo "⚠️  Файл $SSH_CONFIG не найден. Пропускаю настройку SSH."
fi

printf "✅  Готово! Сервер защищён и готов к работе.\n\n"

# === ПЕРЕЗАГРУЗКА С ВОЗМОЖНОСТЬЮ ОТМЕНЫ ===
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
