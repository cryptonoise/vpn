#!/bin/bash

# Завершаем работу при любой ошибке
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

# === Обновление системы с выводом основных моментов ===
echo "──────────────────────────────────────"
printf "🔄  Обновление системы...\n"

echo "• Обновление списка пакетов..."
apt-get update

echo "• Обновление пакетов системы..."
apt-get upgrade -y -o Dpkg::Options::="--force-confdef" -o Dpkg::Options::="--force-confold"

echo "• Обновление дистрибутива (dist-upgrade)..."
apt-get dist-upgrade -y -o Dpkg::Options::="--force-confdef" -o Dpkg::Options::="--force-confold"

echo "• Удаление ненужных пакетов..."
apt-get autoremove -y

echo "──────────────────────────────────────"
printf "✅  Система успешно обновлена!\n\n"

# === Установка пакетов с пошаговым выводом ===
echo "──────────────────────────────────────"
for pkg in unattended-upgrades fail2ban htop iotop nethogs; do
    if ! dpkg -s "$pkg" &>/dev/null; then
        echo "• Устанавливаем $pkg..."
        apt-get install -y --no-install-recommends "$pkg"
    else
        echo "• Пакет $pkg уже установлен"
    fi
done

echo "• Включаем и запускаем fail2ban..."
systemctl enable fail2ban || true
systemctl start fail2ban || true
echo "──────────────────────────────────────"

# === Создание пользователя suser ===
SUSER="suser"
PW_QUAL_CONF="/etc/security/pwquality.conf"
PW_QUAL_BACKUP=""
REPORT_PASS="(не изменён)"

relax_pwquality() {
    if [ -f "$PW_QUAL_CONF" ]; then
        PW_QUAL_BACKUP="${PW_QUAL_CONF}.bak.$$"
        cp -p "$PW_QUAL_CONF" "$PW_QUAL_BACKUP" || true
    fi
    cat >"$PW_QUAL_CONF" <<'EOF'
# Временные упрощённые правила паролей
minlen = 4
dcredit = 0
ucredit = 0
ocredit = 0
lcredit = 0
difok = 1
EOF
    chmod 644 "$PW_QUAL_CONF" || true
}

restore_pwquality() {
    if [ -n "$PW_QUAL_BACKUP" ] && [ -f "$PW_QUAL_BACKUP" ]; then
        mv -f "$PW_QUAL_BACKUP" "$PW_QUAL_CONF" || true
    fi
}

echo "──────────────────────────────────────"
if ! id -u "$SUSER" &>/dev/null; then
    printf "👤  Создаём пользователя %s...\n" "$SUSER"
    useradd -m -s /bin/bash -G sudo "$SUSER"

    if [ -n "${SUSER_PASS-}" ]; then
        printf "🔑  Устанавливаем пароль из переменной окружения SUSER_PASS...\n"
        relax_pwquality
        echo "${SUSER}:${SUSER_PASS}" | chpasswd
        REPORT_PASS="${SUSER_PASS}"
        restore_pwquality
        printf "✅  Пароль успешно установлен.\n\n"
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
                restore_pwquality
                printf "✅  Пароль успешно установлен.\n\n"
                REPORT_PASS="${password}"
                break
            else
                restore_pwquality
                printf "❌  Ошибка установки пароля. Попробуйте другой.\n"
            fi
        done
    fi
else
    printf "👤  Пользователь %s уже существует — пропускаем создание.\n\n" "$SUSER"
fi

# === Настройка SSH ===
echo "──────────────────────────────────────"
echo "• Настраиваем SSH: отключаем root, разрешаем Pubkey, включаем пароль"
SSH_CONFIG="/etc/ssh/sshd_config"
if [[ -f "$SSH_CONFIG" ]]; then
    sed -i 's/^#\?PermitRootLogin.*/PermitRootLogin no/' "$SSH_CONFIG"
    sed -i 's/^#\?PubkeyAuthentication.*/PubkeyAuthentication yes/' "$SSH_CONFIG"
    sed -i 's/^#\?PasswordAuthentication.*/PasswordAuthentication yes/' "$SSH_CONFIG"
    echo "• Перезапуск SSH сервиса..."
    systemctl restart sshd || true
fi
echo "──────────────────────────────────────"

# === Итоговая информация ===
printf "✅  Готово! Сервер защищён и готов к работе.\n"
printf "   • Пользователь: %s\n" "$SUSER"
printf "   • Пароль: %s\n" "$REPORT_PASS"
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
