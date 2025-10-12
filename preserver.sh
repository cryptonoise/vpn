#!/bin/bash

printf "\033c"
export DEBIAN_FRONTEND=noninteractive
export APT_LISTCHANGES_FRONTEND=none

printf "🚀  Начинаю базовую настройку безопасности сервера...\n\n"

# === ГАРАНТИРОВАННОЕ ВОССТАНОВЛЕНИЕ СОСТОЯНИЯ ПАКЕТОВ ===
printf "🔧  Гарантированное восстановление состояния пакетов...\n"

# Удаляем все lock-файлы
rm -f /var/lib/dpkg/lock /var/lib/dpkg/lock-frontend
rm -f /var/cache/apt/archives/lock /var/lib/apt/lists/lock

# Принудительная настройка с подавлением всех запросов
DEBIAN_FRONTEND=noninteractive dpkg --configure -a \
  --force-confdef --force-confold --force-confnew >/dev/null 2>&1 || true

# КРИТИЧЕСКИЙ ШАГ: удаляем файлы в updates/ — они вызывают ошибку!
if [ -d /var/lib/dpkg/updates ] && ls /var/lib/dpkg/updates/* >/dev/null 2>&1; then
    rm -f /var/lib/dpkg/updates/*
    printf "🗑️  Очистка /var/lib/dpkg/updates выполнена.\n"
fi

# Финальная попытка настроить
dpkg --configure -a >/dev/null 2>&1 || true

printf "✅  Состояние пакетов стабилизировано.\n\n"

# === Обновление системы ===
printf "🔄  Обновляю систему...\n"
echo "──────────────────────────────────────"

apt-get update || { echo "❌ apt-get update failed"; exit 1; }

# ЕЩЁ РАЗ: чистим updates/ перед upgrade (на всякий случай)
if [ -d /var/lib/dpkg/updates ] && ls /var/lib/dpkg/updates/* >/dev/null 2>&1; then
    rm -f /var/lib/dpkg/updates/*
fi

apt-get upgrade -y \
  -o Dpkg::Options::="--force-confdef" \
  -o Dpkg::Options::="--force-confold" || { echo "❌ apt-get upgrade failed"; exit 1; }

apt-get dist-upgrade -y \
  -o Dpkg::Options::="--force-confdef" \
  -o Dpkg::Options::="--force-confold" || { echo "❌ dist-upgrade failed"; exit 1; }

apt-get autoremove -y

echo "──────────────────────────────────────"
printf "✅  Система успешно обновлена!\n\n"

printf "\033c"

# ... остальная часть скрипта (пакеты, SSH, пользователь) ...
