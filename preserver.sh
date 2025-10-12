#!/bin/bash

# Очистка экрана
printf "\033c"

export DEBIAN_FRONTEND=noninteractive
export APT_LISTCHANGES_FRONTEND=none

printf "🚀  Начинаю базовую настройку безопасности сервера...\n\n"

# === ФУНКЦИЯ: автоматическое восстановление dpkg ===
auto_fix_dpkg() {
    printf "🔧  Принудительно восстанавливаю dpkg... "
    if DEBIAN_FRONTEND=noninteractive dpkg --configure -a \
        -o Dpkg::Options::="--force-confdef" \
        -o Dpkg::Options::="--force-confold"; then
        printf "✅  dpkg восстановлен.\n"
    else
        echo "❌  Критическая ошибка: dpkg не удалось восстановить."
        exit 1
    fi
}

# === ШАГ 0: удаляем возможные блокировки ===
for lock in /var/lib/dpkg/lock /var/lib/dpkg/lock-frontend /var/lib/apt/lists/lock /var/cache/apt/archives/lock; do
    if [ -f "$lock" ]; then
        printf "🔒  Удаляю заблокированный файл: %s\n" "$lock"
        rm -f "$lock"
    fi
done

# === ШАГ 1: Восстановление dpkg ДО обновления ===
auto_fix_dpkg

# === ШАГ 2: Обновление системы ===
printf "🔄  Обновляю систему...\n"
echo "──────────────────────────────────────"

if ! apt-get update -y; then
    echo "❌ Ошибка: apt-get update завершился неудачно."
    exit 1
fi

# Снова принудительно исправляем dpkg на случай любых изменений после update
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

# === Продолжение установки пакетов, SSH, пользователя и т.д. ===
# … (оставляем без изменений, как в предыдущем скрипте)

