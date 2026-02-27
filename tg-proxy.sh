#!/bin/sh
# 🚀 MTProto Proxy Installer для Telegram (Clean Version)

set -e

# Цвета для вывода
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# -------------------------------
# 🔹 Функция спиннера
# -------------------------------
spinner() {
    text="$1"
    shift
    cmd="$@"

    $cmd >/dev/null 2>&1 &
    pid=$!

    chars="/-\|"
    i=0

    while kill -0 $pid 2>/dev/null; do
        c=$(expr substr "$chars" $((i % 4 + 1)) 1)
        printf "\r%s %s" "$text" "$c"
        i=$((i+1))
        sleep 0.1
    done

    wait $pid
    printf "\r%s ✅\n" "$text"
}

# -------------------------------
# Приветственное сообщение
# -------------------------------
show_welcome() {
    clear
    printf "${BLUE}╔════════════════════════════════════════╗${NC}\n"
    printf "${BLUE}║  📡 MTProto Proxy для Telegram         ║${NC}\n"
    printf "${BLUE}╚════════════════════════════════════════╝${NC}\n"
    printf "\n"
    printf "${GREEN}Что делает скрипт:${NC}\n"
    printf "  • Проверяет Docker\n"
    printf "  • Настраивает фаервол (UFW)\n"
    printf "  • Разворачивает MTProto-прокси с маскировкой под HTTPS\n"
    printf "  • Генерирует ссылку для подключения в Telegram\n"
    printf "\n"
    printf "${YELLOW}🚀 Начинаем...${NC}\n\n"
}

# -------------------------------
# Проверка root
# -------------------------------
check_root() {
    if [ "$(id -u)" -ne 0 ]; then
        printf "❌ Скрипт требует прав root. Запустите с sudo.\n" >&2
        exit 1
    fi
}

# -------------------------------
# Получение IP сервера
# -------------------------------
get_server_ip() {
    curl -s4 https://ifconfig.me 2>/dev/null || curl -s4 https://api.ipify.org 2>/dev/null || echo "0.0.0.0"
}

# -------------------------------
# Установка зависимостей (ПУСТАЯ - ничего не делаем)
# -------------------------------
install_deps() {
    :
}

# -------------------------------
# Установка Docker
# -------------------------------
install_docker() {
    if ! command -v docker >/dev/null 2>&1; then
        spinner "🐳 Устанавливаю Docker..." sh -c "curl -fsSL https://get.docker.com | sh"
    else
        printf "✅ Docker уже установлен\n"
    fi
}

# -------------------------------
# Настройка фаервола
# -------------------------------
setup_firewall() {
    printf "🔥 Настройка UFW...\n"
    ufw default deny incoming >/dev/null 2>&1
    ufw default allow outgoing >/dev/null 2>&1
    ufw allow 22/tcp >/dev/null 2>&1
    ufw allow "${PROXY_PORT}"/tcp >/dev/null 2>&1
    [ "${PROXY_PORT}" != "443" ] && ufw allow 443/tcp >/dev/null 2>&1
    printf "y\n" | ufw enable >/dev/null 2>&1
    printf "✅ Фаервол настроен (порт %s открыт)\n" "${PROXY_PORT}"
}

# -------------------------------
# Параметры (автоматически)
# -------------------------------
ask_params() {
    printf "\n⚙️  Настройка прокси\n\n"

    PROXY_PORT="${PROXY_PORT:-8443}"
    FAKE_TLS_DOMAIN="${FAKE_TLS_DOMAIN:-yastatic.net}"
    PROXY_DOMAIN="${PROXY_DOMAIN:-$(get_server_ip)}"

    printf "🔹 Порт прокси: %s\n" "$PROXY_PORT"
    printf "🔹 Fake TLS домен: %s\n" "$FAKE_TLS_DOMAIN"
    printf "ℹ️  Используем IP/домен: %s\n" "$PROXY_DOMAIN"
}

# -------------------------------
# Генерация секрета
# -------------------------------
generate_secret() {
    SECRET=$(docker run --rm nineseconds/mtg:2 generate-secret --hex "${FAKE_TLS_DOMAIN}")
    printf "✅ Секрет сгенерирован\n"
}

# -------------------------------
# Запуск контейнера
# -------------------------------
run_proxy() {
    spinner "🚀 Запуск MTProxy контейнера..." docker run -d \
        --name telegram \
        --restart unless-stopped \
        -p "${PROXY_PORT}":8443 \
        nineseconds/mtg:2 \
        simple-run -n 1.1.1.1 -i prefer-ipv4 0.0.0.0:8443 "${SECRET}"
}

# -------------------------------
# Сохранение секрета
# -------------------------------
save_secret() {
    printf "%s\n" "${SECRET}" > ~/mtproxy_secret.txt
    chmod 600 ~/mtproxy_secret.txt
    printf "ℹ️  Секрет сохранён в ~/mtproxy_secret.txt\n"
}

# -------------------------------
# Вывод результата
# -------------------------------
show_result() {
    printf "\n${GREEN}╔════════════════════════════════════════╗${NC}\n"
    printf "${GREEN}║  🎉 Прокси готов к использованию!      ║${NC}\n"
    printf "${GREEN}╚════════════════════════════════════════╝${NC}\n"
    printf "\n"
    printf "${YELLOW}📋 Ссылка для Telegram:${NC}\n"
    printf "https://t.me/proxy?server=%s&port=%s&secret=%s\n" "$PROXY_DOMAIN" "$PROXY_PORT" "$SECRET"
    printf "\n"
    printf "${YELLOW}💡 Как подключить:${NC}\n"
    printf "  1. Скопируйте ссылку выше\n"
    printf "  2. Откройте её в Telegram\n"
    printf "  3. Нажмите «Добавить прокси»\n"
    printf "  4. Проверьте: Настройки → Данные и память → Прокси → ✅\n"
    printf "\n"
    printf "${BLUE}🔧 Полезные команды:${NC}\n"
    printf "  docker restart telegram          # перезапустить\n"
    printf "  docker stop telegram && docker rm telegram  # удалить\n"
    printf "\n"
}

# -------------------------------
# Основная функция
# -------------------------------
main() {
    show_welcome
    check_root
    install_deps
    install_docker
    ask_params
    setup_firewall
    generate_secret
    run_proxy
    save_secret
    show_result
}

# -------------------------------
# Запуск
# -------------------------------
main
