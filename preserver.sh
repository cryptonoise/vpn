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

# === Установка пакетов (тихо) ===
install_if_missing() {
    local pkg="$1"
    if ! dpkg -s "$pkg" &>/dev/null; then
        DEBIAN_FRONTEND=noninteractive \
        apt-get install -y --no-install-recommends \
        -o Dpkg::Options::="--force-confdef" \
        -o Dpkg::Options::="--force-confold" \
        "$pkg" &>/dev/null
    fi
}

for pkg in unattended-upgrades fail2ban htop iotop nethogs; do
    install_if_missing "$pkg"
done

systemctl enable fail2ban --quiet
systemctl start fail2ban --quiet

# === Создание пользователя suser ===
if ! id -u suser &>/dev/null; then
    printf "👤  Создаю пользователя suser...\n"
    useradd -m -s /bin/bash -G sudo suser

    # Проверяем, есть ли интерактивный терминал
    if [ ! -t 0 ]; then
        echo "❌  Ошибка: невозможно ввести пароль — скрипт запущен без интерактивного ввода (например, через curl | bash)."
        echo "   Перезапустите скрипт вручную в терминале, чтобы ввести пароль."
        exit 1
    fi

    while true; do
        printf "🔒  Введите пароль для пользователя suser: "
        read -s password
        printf "\n"

        if [ -z "$password" ]; then
            printf "⚠️  Пароль не может быть пустым. Попробуйте снова.\n"
            continue
        fi

        # Проверка длины пароля (рекомендуется хотя бы 8 символов)
        if [ ${#password} -lt 8 ]; then
            printf "⚠️  Пароль должен содержать минимум 8 символов. Попробуйте снова.\n"
            continue
        fi

        if echo "suser:$password" | chpasswd; then
            printf "✅  Пароль успешно установлен.\n\n"
            break
        else
            printf "❌  Не удалось установить пароль. Попробуйте снова.\n"
        fi
    done
else
    printf "👤  Пользователь suser уже существует — пропускаю создание.\n\n"
fi


# === Настройка SSH ===
SSH_CONFIG="/etc/ssh/sshd_config"
if [[ -f "$SSH_CONFIG" ]]; then
    sed -i 's/^#\?PermitRootLogin.*/PermitRootLogin no/' "$SSH_CONFIG"
    sed -i 's/^#\?PubkeyAuthentication.*/PubkeyAuthentication yes/' "$SSH_CONFIG"
    sed -i 's/^#\?PasswordAuthentication.*/PasswordAuthentication yes/' "$SSH_CONFIG"
    systemctl restart sshd >/dev/null 2>&1
fi

# === ФИНАЛЬНОЕ СООБЩЕНИЕ ===
printf "✅  Готово! Сервер защищён и готов к работе.\n"
printf "   • Пользователь: suser\n"
printf "   • Пароль: задан вами при создании\n"
printf "   • Вход по SSH-ключу: разрешён (если ~/.ssh/authorized_keys существует)\n"
printf "   • Root-доступ: отключён\n\n"

# === Перезагрузка: простой вопрос ===
printf "🔄  Перезагрузить сервер? [y/N]: "
read -r response

case "$response" in
    [yY]|[yY][eE][sS])
        echo
        echo "🔁  Перезагрузка запущена..."
        reboot
        ;;
    *)
        echo
        echo "⏹  Перезагрузка отменена. Сервер остаётся включённым."
        exit 0
        ;;
esac
