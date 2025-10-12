#!/bin/bash

# Завершаем работу при ошибках
set -euo pipefail

# Очищаем экран
printf "\033c"

export DEBIAN_FRONTEND=noninteractive
export APT_LISTCHANGES_FRONTEND=none

printf "🚀  Начинаю базовую настройку безопасности сервера...\n\n"

# === Проверка и восстановление dpkg при сбоях ===
if [ -d /var/lib/dpkg/updates ] && ls /var/lib/dpkg/updates/* >/dev/null 2>&1; then
    printf "🔧  Обнаружены следы прерванной установки. Восстанавливаю систему...\n"
    rm -f /var/lib/dpkg/lock /var/lib/dpkg/lock-frontend
    rm -f /var/cache/apt/archives/lock /var/lib/apt/lists/lock
    dpkg --configure -a --force-confdef --force-confold || true
    rm -f /var/lib/dpkg/updates/*
    dpkg --configure -a || true
    printf "✅  Восстановление завершено.\n\n"
fi

# === Обновление системы (видимый вывод) ===
printf "🔄  Обновляю систему...\n"
echo "──────────────────────────────────────"

apt-get update || { echo "❌ apt-get update failed"; exit 1; }
apt-get upgrade -y -o Dpkg::Options::="--force-confdef" -o Dpkg::Options::="--force-confold" || { echo "❌ upgrade failed"; exit 1; }
apt-get dist-upgrade -y -o Dpkg::Options::="--force-confdef" -o Dpkg::Options::="--force-confold" || { echo "❌ dist-upgrade failed"; exit 1; }
apt-get autoremove -y

echo "──────────────────────────────────────"
printf "✅  Система успешно обновлена!\n\n"

# Очищаем экран
printf "\033c"

# === Установка необходимых пакетов ===
install_if_missing() {
    local pkg="$1"
    if ! dpkg -s "$pkg" &>/dev/null; then
        DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends "$pkg"
    fi
}

for pkg in unattended-upgrades fail2ban htop iotop nethogs; do
    install_if_missing "$pkg"
done

systemctl enable fail2ban --quiet || true
systemctl start fail2ban --quiet || true

# === Создание пользователя suser ===
SUSER="suser"
PW_QUAL_CONF="/etc/security/pwquality.conf"
PW_QUAL_BACKUP=""
USER_PASSWORD=""

# Временное ослабление проверки сложности пароля
relax_pwquality() {
    if [ -f "$PW_QUAL_CONF" ]; then
        PW_QUAL_BACKUP="${PW_QUAL_CONF}.bak.$$"
        cp -p "$PW_QUAL_CONF" "$PW_QUAL_BACKUP" || true
    fi

    cat >"$PW_QUAL_CONF" <<'EOF'
# Временные упрощённые правила паролей (создано скриптом)
minlen = 4
dcredit = 0
ucredit = 0
ocredit = 0
lcredit = 0
difok = 1
EOF
    chmod 644 "$PW_QUAL_CONF" || true
}

# Восстановление исходных правил
restore_pwquality() {
    if [ -n "$PW_QUAL_BACKUP" ] && [ -f "$PW_QUAL_BACKUP" ]; then
        mv -f "$PW_QUAL_BACKUP" "$PW_QUAL_CONF" || true
    fi
}

if ! id -u "$SUSER" &>/dev/null; then
    printf "👤  Создаю пользователя %s...\n" "$SUSER"
    useradd -m -s /bin/bash -G sudo "$SUSER"

    # Если пароль передан через переменную окружения
    if [ -n "${SUSER_PASS-}" ]; then
        USER_PASSWORD="$SUSER_PASS"
        printf "🔑  Устанавливаю пароль из переменной окружения SUSER_PASS...\n"
        relax_pwquality
        if echo "${SUSER}:${SUSER_PASS}" | chpasswd; then
            printf "✅  Пароль успешно установлен из SUSER_PASS.\n\n"
        else
            printf "❌  Не удалось установить пароль из SUSER_PASS.\n"
            exit 1
        fi
        restore_pwquality

    # Если пароль не задан — интерактивный ввод
    else
        if [ ! -t 0 ]; then
            echo "❌  Ошибка: интерактивный ввод невозможен (нет TTY)."
            echo "   Запустите скрипт вручную или задайте пароль через SUSER_PASS."
            exit 1
        fi

        while true; do
            printf "🔒  Введите пароль для пользователя %s: " "$SUSER"
            read -s password
            printf "\n"

            if [ -z "$password" ]; then
                printf "⚠️  Пароль не может быть пустым. Попробуйте снова.\n"
                continue
            fi

            relax_pwquality
            if echo "${SUSER}:${password}" | chpasswd; then
                USER_PASSWORD="$password"
                printf "✅  Пароль успешно установлен.\n\n"
                restore_pwquality
                break
            else
                restore_pwquality
                printf "❌  Ошибка установки пароля. Попробуйте другой.\n"
                continue
            fi
        done
    fi
else
    printf "👤  Пользователь %s уже существует — пропускаю создание.\n\n" "$SUSER"
fi

# === Настройка SSH ===
SSH_CONFIG="/etc/ssh/sshd_config"
if [[ -f "$SSH_CONFIG" ]]; then
    sed -i 's/^#\?PermitRootLogin.*/PermitRootLogin no/' "$SSH_CONFIG"
    sed -i 's/^#\?PubkeyAuthentication.*/PubkeyAuthentication yes/' "$SSH_CONFIG"
    sed -i 's/^#\?PasswordAuthentication.*/PasswordAuthentication yes/' "$SSH_CONFIG"
    systemctl restart sshd >/dev/null 2>&1 || true
fi

# === Итоговая информация ===
printf "✅  Готово! Сервер защищён и готов к работе.\n"
printf "   • Пользователь: %s\n" "$SUSER"
if [ -n "${SUSER_PASS-}" ]; then
    printf "   • Пароль: %s\n" "$SUSER_PASS"
elif [ -n "$USER_PASSWORD" ]; then
    printf "   • Пароль: %s\n" "$USER_PASSWORD"
else
    printf "   • Пароль: введён вручную (не удалось отобразить)\n"
fi
printf "   • Вход по SSH-ключу: разрешён (если ~/.ssh/authorized_keys существует)\n"
printf "   • Root-доступ: отключён\n\n"

# === Перезагрузка ===
if [ -t 0 ]; then
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
            ;;
    esac
else
    echo "ℹ️  Неинтерактивный режим: пропуск запроса на перезагрузку."
    echo "   Чтобы перезагрузить вручную, выполните: sudo reboot"
fi
