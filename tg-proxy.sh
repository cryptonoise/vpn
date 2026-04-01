#!/bin/sh

set -e

# Цвета
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# -------------------------------
# Приветствие
# -------------------------------
show_welcome() {
    clear
    printf "${BLUE}╔════════════════════════════════════════╗${NC}\n"
    printf "${BLUE}║  📡 MTProto Proxy для Telegram         ║${NC}\n"
    printf "${BLUE}╚════════════════════════════════════════╝${NC}\n"
    printf "\n"
    printf "${GREEN}Что делает скрипт:${NC}\n"
    printf "  • Проверяет Docker\n"
    printf "  • Настраивает фаервол (опционально)\n"
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
# IP сервера
# -------------------------------
get_server_ip() {
    curl -s4 https://ifconfig.me 2>/dev/null || curl -s4 https://api.ipify.org 2>/dev/null || echo "0.0.0.0"
}

# -------------------------------
# Зависимости
# -------------------------------
install_deps() {
    :
}

# -------------------------------
# Исправление dpkg
# -------------------------------
fix_dpkg() {
    printf "${RED}⚠️  Обнаружена ошибка. Исправляю...${NC}\n"
    pkill -9 -f "dpkg" 2>/dev/null || true
    pkill -9 -f "apt" 2>/dev/null || true
    rm -f /var/lib/dpkg/lock-frontend /var/lib/dpkg/lock /var/cache/apt/archives/lock /var/lib/apt/lists/lock
    dpkg --configure -a 2>/dev/null || true
    apt-get install -f -y 2>/dev/null || true
    apt-get update -qq 2>/dev/null || true
    printf "${GREEN}✅ Система исправлена. Повторяю...${NC}\n\n"
}

# -------------------------------
# Установка Docker
# -------------------------------
install_docker() {
    if command -v docker >/dev/null 2>&1; then
        printf "✅ Docker уже установлен\n\n"
        return 0
    fi
    
    printf "${BLUE}────────────────────────────────────────${NC}\n"
    printf "🐳 Устанавливаю Docker...\n"
    printf "${BLUE}────────────────────────────────────────${NC}\n"
    
    if curl -fsSL https://get.docker.com | sh 2>/dev/null; then
        printf "\n${GREEN}✅ Docker установлен${NC}\n\n"
        return 0
    fi
    
    fix_dpkg
    
    if curl -fsSL https://get.docker.com | sh; then
        printf "\n${GREEN}✅ Docker установлен${NC}\n\n"
        return 0
    fi
    
    printf "${RED}❌ Не удалось установить Docker${NC}\n" >&2
    exit 1
}

# -------------------------------
# Интерактивные параметры
# -------------------------------
ask_params() {
    printf "${BLUE}────────────────────────────────────────${NC}\n"
    printf "⚙️  Настройка прокси\n"
    printf "${BLUE}────────────────────────────────────────${NC}\n\n"

    # Порт
    printf "🔹 Введите порт прокси [по умолчанию - 8443]: "
    read -r PROXY_PORT_INPUT < /dev/tty || true
    PROXY_PORT=${PROXY_PORT_INPUT:-8443}
    case "$PROXY_PORT" in
        ''|*[!0-9]*) printf "⚠️  Некорректный порт, используем 8443\n"; PROXY_PORT=8443 ;;
        *) if [ "$PROXY_PORT" -lt 1 ] || [ "$PROXY_PORT" -gt 65535 ]; then
               printf "⚠️  Некорректный порт, используем 8443\n"; PROXY_PORT=8443
           fi ;;
    esac
    printf "✅ Порт: %s\n\n" "$PROXY_PORT"

    # Fake TLS
    while true; do
        printf "🔹 Введите Fake TLS домен: "
        read -r FAKE_TLS_DOMAIN_INPUT < /dev/tty || true
        FAKE_TLS_DOMAIN_INPUT=$(printf "%s" "$FAKE_TLS_DOMAIN_INPUT" | tr -d '[:space:]') 
        
        if [ -n "$FAKE_TLS_DOMAIN_INPUT" ]; then
            FAKE_TLS_DOMAIN="$FAKE_TLS_DOMAIN_INPUT"
            break
        else
            printf "${RED}⚠️  Домен не может быть пустым. Попробуйте снова.${NC}\n"
        fi
    done
    printf "✅ Fake TLS домен: %s\n\n" "$FAKE_TLS_DOMAIN"

    # Домен для ссылки
    printf "🔹 Введите ваш домен для ссылки\n   (или Enter чтобы использовать IP этого сервера): "
    read -r PROXY_DOMAIN_INPUT < /dev/tty || true
    if [ -z "$PROXY_DOMAIN_INPUT" ]; then
        PROXY_DOMAIN=$(get_server_ip)
        printf "ℹ️  Будет использован IP: %s\n\n" "$PROXY_DOMAIN"
    else
        PROXY_DOMAIN="$PROXY_DOMAIN_INPUT"
        printf "✅ Домен: %s\n\n" "$PROXY_DOMAIN"
    fi
    
    # 🆕 Имя контейнера: из домена (точки → дефисы) или "telegram" по умолчанию
    if [ -n "$PROXY_DOMAIN_INPUT" ]; then
        # Заменяем точки на дефисы, убираем опасные символы
        CONTAINER_NAME=$(printf "%s" "$PROXY_DOMAIN_INPUT" | tr '.' '-' | tr -cd 'a-zA-Z0-9_-')
        # Если имя начинается с дефиса/подчёркивания — добавляем префикс
        case "$CONTAINER_NAME" in
            [-_]*) CONTAINER_NAME="mtg-${CONTAINER_NAME}" ;;
        esac
    else
        CONTAINER_NAME="telegram"
    fi
    printf "✅ Имя контейнера: %s\n\n" "$CONTAINER_NAME"
}

# -------------------------------
# Фаервол
# -------------------------------
setup_firewall() {
    printf "${BLUE}────────────────────────────────────────${NC}\n"
    printf "🔥 Настроить фаервол (UFW)? [Enter - нет | Y - да]: "
    read -r UFW_CHOICE < /dev/tty || true
    UFW_CHOICE=$(printf "%s" "$UFW_CHOICE" | tr '[:lower:]' '[:upper:]')
    
    if [ "$UFW_CHOICE" = "Y" ] || [ "$UFW_CHOICE" = "YES" ]; then
        printf "🔧 Применяю правила UFW...\n"
        ufw default deny incoming 2>/dev/null || true
        ufw default allow outgoing 2>/dev/null || true
        ufw allow 22/tcp 2>/dev/null || true
        ufw allow "${PROXY_PORT}"/tcp 2>/dev/null || true
        [ "${PROXY_PORT}" != "443" ] && ufw allow 443/tcp 2>/dev/null || true
        printf "y\n" | ufw enable 2>/dev/null || true
        
        # Формируем список открытых портов
        OPEN_PORTS="22/tcp, ${PROXY_PORT}/tcp"
        [ "${PROXY_PORT}" != "443" ] && OPEN_PORTS="${OPEN_PORTS}, 443/tcp"
        
        printf "✅ Фаервол настроен\n"
        printf "🔓 Открыты порты: %s\n\n" "$OPEN_PORTS"
    else
        printf "⏭️  Пропущено (фаервол не настроен)\n\n"
    fi
}

# -------------------------------
# Генерация секрета
# -------------------------------
generate_secret() {
    printf "${BLUE}────────────────────────────────────────${NC}\n"
    printf "🔑 Генерация секретного ключа...\n"
    printf "${BLUE}────────────────────────────────────────${NC}\n"
    SECRET=$(docker run --rm nineseconds/mtg:2 generate-secret --hex "${FAKE_TLS_DOMAIN}")
    printf "\n✅ Секрет сгенерирован\n\n"
}

# -------------------------------
# Проверка: какой контейнер занимает порт
# -------------------------------
find_container_by_port() {
    local port="$1"
    # Ищем контейнер, который слушает этот порт через docker-proxy
    docker ps --format "{{.Names}}:{{.Ports}}" | grep ":${port}->" | cut -d: -f1 | head -1
}

# -------------------------------
# Запуск контейнера (с проверкой конфликтов портов)
# -------------------------------
run_proxy() {
    printf "${BLUE}────────────────────────────────────────${NC}\n"
    printf "🚀 Запуск MTProxy контейнера...\n"
    printf "${BLUE}────────────────────────────────────────${NC}\n"
    
    # 🆕 Путь для хранения секрета (уникальный для каждого контейнера)
    SECRET_FILE="/root/mtg-secret-${CONTAINER_NAME}"
    
    # 🔍 Проверка: не занят ли порт другим контейнером
    EXISTING_CONTAINER=$(find_container_by_port "${PROXY_PORT}")
    if [ -n "$EXISTING_CONTAINER" ] && [ "$EXISTING_CONTAINER" != "$CONTAINER_NAME" ]; then
        printf "${YELLOW}⚠️  Порт ${PROXY_PORT} уже занят контейнером '${EXISTING_CONTAINER}'.${NC}\n"
        printf "🔹 Удалить '${EXISTING_CONTAINER}' и освободить порт? [Enter=да / N=нет]: "
        read -r REMOVE_CHOICE < /dev/tty || true
        REMOVE_CHOICE=$(printf "%s" "$REMOVE_CHOICE" | tr '[:upper:]' '[:lower:]')
        
        if [ -z "$REMOVE_CHOICE" ] || [ "$REMOVE_CHOICE" = "y" ] || [ "$REMOVE_CHOICE" = "yes" ]; then
            printf "🗑️  Останавливаю '${EXISTING_CONTAINER}'...\n"
            docker stop "${EXISTING_CONTAINER}" 2>/dev/null || true
            docker rm "${EXISTING_CONTAINER}" 2>/dev/null || true
            printf "✅ Контейнер '${EXISTING_CONTAINER}' удалён, порт ${PROXY_PORT} свободен\n"
        else
            printf "${RED}❌ Порт занят. Скрипт завершён.${NC}\n"
            printf "${BLUE}💡 Выберите другой порт или удалите контейнер вручную:${NC}\n"
            printf "   docker stop ${EXISTING_CONTAINER} && docker rm ${EXISTING_CONTAINER}\n\n"
            exit 1
        fi
    fi
    
    # Проверяем, существует ли контейнер с таким именем
    if docker ps -a --filter name="^/${CONTAINER_NAME}$" --format "{{.ID}}" | grep -q .; then
        printf "${YELLOW}⚠️  Контейнер '${CONTAINER_NAME}' уже существует.${NC}\n"
        printf "🔹 Переустановить контейнер? [Enter=да / N=нет]: "
        read -r REINSTALL_CHOICE < /dev/tty || true
        REINSTALL_CHOICE=$(printf "%s" "$REINSTALL_CHOICE" | tr '[:upper:]' '[:lower:]')
        
        if [ -z "$REINSTALL_CHOICE" ] || [ "$REINSTALL_CHOICE" = "y" ] || [ "$REINSTALL_CHOICE" = "yes" ]; then
            # ✅ Сохраняем старый секрет, если файл есть
            if [ -f "$SECRET_FILE" ]; then
                OLD_SECRET=$(cat "$SECRET_FILE")
                printf "ℹ️  Используем сохранённый секрет\n"
                SECRET="$OLD_SECRET"
            else
                # Генерируем новый, если файла нет
                generate_secret
                printf "%s" "$SECRET" > "$SECRET_FILE"
                chmod 600 "$SECRET_FILE"
            fi
            printf "🗑️  Удаляю старый контейнер...\n"
            docker stop "${CONTAINER_NAME}" 2>/dev/null || true
            docker rm "${CONTAINER_NAME}" 2>/dev/null || true
            printf "✅ Старый контейнер удалён\n"
        else
            printf "\n${YELLOW}⏭️  Прокси не был переустановлен. Скрипт завершён.${NC}\n"
            printf "${BLUE}💡 Чтобы создать новый прокси, запустите скрипт снова и нажмите Enter.${NC}\n\n"
            exit 0
        fi
    else
        # ✅ Новый запуск — генерируем и сохраняем секрет
        generate_secret
        printf "%s" "$SECRET" > "$SECRET_FILE"
        chmod 600 "$SECRET_FILE"
    fi
    
    # Запускаем контейнер с исправленными флагами
    docker run -d \
        --name "${CONTAINER_NAME}" \
        --restart unless-stopped \
        --sysctl net.ipv6.conf.all.disable_ipv6=1 \
        --sysctl net.ipv6.conf.default.disable_ipv6=1 \
        -p "${PROXY_PORT}":8443 \
        -v "${SECRET_FILE}:/secret:ro" \
        nineseconds/mtg:2 \
        simple-run -n 1.1.1.1 -i prefer-ipv4 0.0.0.0:8443 "$(cat "${SECRET_FILE}")"
    
    # Ждём 3 секунды и проверяем, жив ли контейнер
    sleep 3
    if docker ps --filter name="^/${CONTAINER_NAME}$" --format "{{.Status}}" | grep -q "Up"; then
        printf "\n${GREEN}✅ Контейнер '${CONTAINER_NAME}' запущен и работает${NC}\n"
    else
        printf "\n${RED}❌ Контейнер не запустился! Проверьте логи:${NC}\n"
        printf "  docker logs ${CONTAINER_NAME} --tail 20\n"
        exit 1
    fi
    printf "\n"
}

# -------------------------------
# Результат
# -------------------------------
show_result() {
    printf "\n"
    printf "${GREEN}╔════════════════════════════════════════╗${NC}\n"
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
    printf "  docker restart %-20s # перезапустить\n" "${CONTAINER_NAME}"
    printf "  docker stop %-22s && docker rm %-20s # удалить\n" "${CONTAINER_NAME}" "${CONTAINER_NAME}"
    printf "  docker logs %-23s --tail 20 # посмотреть логи\n" "${CONTAINER_NAME}"
    printf "\n"
}

# -------------------------------
# MAIN
# -------------------------------
main() {
    show_welcome
    check_root
    install_deps
    install_docker
    ask_params
    setup_firewall
    run_proxy
    show_result
}

# -------------------------------
# Запуск
# -------------------------------
main
