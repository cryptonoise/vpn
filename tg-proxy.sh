#!/bin/sh
# 🚀 MTProto Proxy Installer для Telegram

set -e

# Цвета для вывода
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# Приветственное сообщение
show_welcome() {
    clear
    printf "${BLUE}╔════════════════════════════════════════╗${NC}\n"
    printf "${BLUE}║  📡 MTProto Proxy для Telegram         ║${NC}\n"
    printf "${BLUE}╚════════════════════════════════════════╝${NC}\n"
    printf "\n"
    printf "${GREEN}Что делает скрипт:${NC}\n"
    printf "  • Устанавливает Docker и зависимости\n"
    printf "  • Настраивает фаервол (UFW)\n"
    printf "  • Разворачивает MTProto-прокси с маскировкой под HTTPS\n"
    printf "  • Генерирует ссылку для подключения в Telegram\n"
    printf "\n"
    
    if [ -t 0 ]; then
        printf "${YELLOW}Нажмите [Enter] чтобы начать установку...${NC}\n"
        read -r dummy || true
    else
        printf "${YELLOW}Запуск установки...${NC}\n"
        sleep 1
    fi
}

# Проверка прав root
check_root() {
    if [ "$(id -u)" -ne 0 ]; then
        printf "❌ Скрипт требует прав root. Запустите с sudo.\n" >&2
        exit 1
    fi
}

# Получение внешнего IP сервера
get_server_ip() {
    curl -s4 https://ifconfig.me 2>/dev/null || curl -s4 https://api.ipify.org 2>/dev/null || echo "0.0.0.0"
}

# Установка зависимостей
install_deps() {
    printf "🔄 Обновление системы и установка зависимостей...\n"
    apt update -qq >/dev/null 2>&1
    apt upgrade -y -qq >/dev/null 2>&1
    apt install -y -qq curl git dnsutils ufw >/dev/null 2>&1
    printf "✅ Зависимости установлены\n"
}

# Установка Docker
install_docker() {
    if ! command -v docker >/dev/null 2>&1; then
        printf "🐳 Установка Docker...\n"
        curl -fsSL https://get.docker.com | sh >/dev/null 2>&1
        printf "✅ Docker установлен\n"
    else
        printf "✅ Docker уже установлен\n"
    fi
}

# Настройка фаервола
setup_firewall() {
    printf "🔥 Настройка UFW...\n"
    ufw default deny incoming >/dev/null 2>&1
    ufw default allow outgoing >/dev/null 2>&1
    ufw allow 22/tcp >/dev/null 2>&1
    ufw allow "${PROXY_PORT}"/tcp >/dev/null 2>&1
    if [ "${PROXY_PORT}" != "443" ]; then
        ufw allow 443/tcp >/dev/null 2>&1
    fi
    printf "y\n" | ufw enable >/dev/null 2>&1
    printf "✅ Фаервол настроен (порт %s открыт)\n" "${PROXY_PORT}"
}

# Запрос параметров
ask_params() {
    printf "\n"
    printf "⚙️  Настройка прокси\n"
    printf "\n"
    
    printf "🔹 Введите порт для прокси [8443]: "
    read -r PROXY_PORT_INPUT || true
    PROXY_PORT=${PROXY_PORT_INPUT:-8443}
    
    # Валидация порта (POSIX-совместимая)
    case "${PROXY_PORT}" in
        ''|*[!0-9]*) 
            printf "⚠️  Некорректный порт, используем 8443\n"
            PROXY_PORT=8443
            ;;
        *)
            if [ "${PROXY_PORT}" -lt 1 ] || [ "${PROXY_PORT}" -gt 65535 ]; then
                printf "⚠️  Некорректный порт, используем 8443\n"
                PROXY_PORT=8443
            fi
            ;;
    esac
    printf "✅ Порт: %s\n" "${PROXY_PORT}"
    
    printf "\n"
    printf "🔹 Введите Fake TLS домен [yastatic.net]: "
    read -r FAKE_TLS_DOMAIN_INPUT || true
    FAKE_TLS_DOMAIN=${FAKE_TLS_DOMAIN_INPUT:-yastatic.net}
    printf "✅ Fake TLS домен: %s\n" "${FAKE_TLS_DOMAIN}"
    
    printf "\n"
    printf "🔹 Введите ваш домен (или нажмите Enter, чтобы использовать IP этого сервера): "
    read -r PROXY_DOMAIN_INPUT || true
    if [ -z "${PROXY_DOMAIN_INPUT}" ]; then
        PROXY_DOMAIN=$(get_server_ip)
        printf "ℹ️  Будет использован IP: %s\n" "${PROXY_DOMAIN}"
    else
        PROXY_DOMAIN="${PROXY_DOMAIN_INPUT}"
        printf "✅ Домен: %s\n" "${PROXY_DOMAIN}"
    fi
}

# Генерация секрета
generate_secret() {
    printf "🔑 Генерация секретного ключа...\n"
    SECRET=$(docker run --rm nineseconds/mtg:2 generate-secret --hex "${FAKE_TLS_DOMAIN}")
    printf "✅ Секрет сгенерирован\n"
}

# Запуск контейнера
run_proxy() {
    printf "🚀 Запуск MTProxy контейнера...\n"
    docker run -d \
        --name telegram \
        --restart unless-stopped \
        -p "${PROXY_PORT}":8443 \
        nineseconds/mtg:2 \
        simple-run -n 1.1.1.1 -i prefer-ipv4 0.0.0.0:8443 "${SECRET}" >/dev/null 2>&1
    sleep 2
    if docker ps | grep -q telegram; then
        printf "✅ Контейнер запущен\n"
    else
        printf "❌ Не удалось запустить контейнер\n" >&2
        exit 1
    fi
}

# Вывод результата
show_result() {
    printf "\n"
    printf "${GREEN}╔════════════════════════════════════════╗${NC}\n"
    printf "${GREEN}║  🎉 Прокси готов к использованию!      ║${NC}\n"
    printf "${GREEN}╚════════════════════════════════════════╝${NC}\n"
    printf "\n"
    printf "${YELLOW}📋 Ссылка для Telegram:${NC}\n"
    printf "https://t.me/proxy?server=%s&port=%s&secret=%s\n" "${PROXY_DOMAIN}" "${PROXY_PORT}" "${SECRET}"
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

# Сохранение секрета
save_secret() {
    printf "%s\n" "${SECRET}" > ~/mtproxy_secret.txt
    chmod 600 ~/mtproxy_secret.txt
    printf "ℹ️  Секрет сохранён в ~/mtproxy_secret.txt\n"
}

# Основная функция
main() {
    show_welcome
    check_root
    install_deps
    install_docker
    setup_firewall
    ask_params
    generate_secret
    run_proxy
    save_secret
    show_result
}

# Запуск
main
