/**
 * 🚀 MTProto Proxy Installer for Telegram
 * Worker для tg.travelarium.ph
 * 
 * Деплой: Cloudflare Dashboard → Workers & Pages → Create Worker
 * Затем: Triggers → Custom Domains → tg.travelarium.ph
 */

export default {
  async fetch(request) {
    const url = new URL(request.url);
    
    // Блокируем всё, кроме GET запросов к корню домена
    if (request.method !== 'GET') {
      return new Response('Method Not Allowed', { status: 405 });
    }
    
    // Отдаём скрипт только на запрос к корню (/)
    if (url.pathname !== '/' && url.pathname !== '/install.sh') {
      return new Response('Not Found', { status: 404 });
    }

    // 📜 Сам bash-скрипт (полная версия)
    const installerScript = `#!/bin/bash
# 🚀 MTProto Proxy Installer for Telegram
# Запуск: curl -fsSL https://tg.travelarium.ph | sudo bash

set -e

# Цвета для вывода
RED='\\\\033[0;31m'
GREEN='\\\\033[0;32m'
YELLOW='\\\\033[1;33m'
BLUE='\\\\033[0;34m'
NC='\\\\033[0m'

# Приветственное сообщение
show_welcome() {
    clear
    echo -e "\${BLUE}╔════════════════════════════════════════╗\${NC}"
    echo -e "\${BLUE}║  📡 MTProto Proxy для Telegram         ║\${NC}"
    echo -e "\${BLUE}║  Быстрая настройка прокси с Fake TLS   ║\${NC}"
    echo -e "\${BLUE}╚════════════════════════════════════════╝\${NC}"
    echo ""
    echo -e "\${GREEN}Что делает скрипт:\${NC}"
    echo "  • Устанавливает Docker и зависимости"
    echo "  • Настраивает фаервол (UFW)"
    echo "  • Разворачивает MTProto-прокси с маскировкой под HTTPS"
    echo "  • Генерирует ссылку для подключения в Telegram"
    echo ""
    echo -e "\${YELLOW}Нажмите [Enter] чтобы начать установку...\${NC}"
    read -r
}

# Логирование с эмодзи
log_info()  { echo -e "\${BLUE}[ℹ️]\${NC} \$1"; }
log_ok()    { echo -e "\${GREEN}[✅]\${NC} \$1"; }
log_warn()  { echo -e "\${YELLOW}[⚠️]\${NC} \$1"; }
log_error() { echo -e "\${RED}[❌]\${NC} \$1"; }

# Проверка прав root
check_root() {
    if [[ \$EUID -ne 0 ]]; then
        log_error "Скрипт требует прав root. Запустите с sudo."
        exit 1
    fi
}

# Получение внешнего IP сервера
get_server_ip() {
    curl -s4 https://ifconfig.me 2>/dev/null || curl -s4 https://api.ipify.org 2>/dev/null || echo "0.0.0.0"
}

# Установка зависимостей (минимальный вывод)
install_deps() {
    log_info "Обновление системы и установка зависимостей..."
    apt update -qq >/dev/null 2>&1
    apt upgrade -y -qq >/dev/null 2>&1
    apt install -y -qq curl git dnsutils ufw >/dev/null 2>&1
    log_ok "Зависимости установлены"
}

# Установка Docker (тихий режим)
install_docker() {
    if ! command -v docker &> /dev/null; then
        log_info "Установка Docker..."
        curl -fsSL https://get.docker.com | sh >/dev/null 2>&1
        log_ok "Docker установлен"
    else
        log_ok "Docker уже установлен"
    fi
}

# Настройка фаервола
setup_firewall() {
    log_info "Настройка UFW..."
    ufw default deny incoming >/dev/null 2>&1
    ufw default allow outgoing >/dev/null 2>&1
    ufw allow 22/tcp >/dev/null 2>&1
    ufw allow "\$PROXY_PORT"/tcp >/dev/null 2>&1
    if [[ "\$PROXY_PORT" != "443" ]]; then
        ufw allow 443/tcp >/dev/null 2>&1
    fi
    echo "y" | ufw enable >/dev/null 2>&1
    log_ok "Фаервол настроен (порт \$PROXY_PORT открыт)"
}

# Запрос параметров у пользователя
ask_params() {
    echo ""
    log_info "Настройка прокси"
    echo ""
    
    read -rp "🔹 Введите порт для прокси [8443]: " PROXY_PORT
    PROXY_PORT=\${PROXY_PORT:-8443}
    if ! [[ "\$PROXY_PORT" =~ ^[0-9]+$ ]] || [ "\$PROXY_PORT" -lt 1 ] || [ "\$PROXY_PORT" -gt 65535 ]; then
        log_warn "Некорректный порт, используем 8443"
        PROXY_PORT=8443
    fi
    log_ok "Порт: \$PROXY_PORT"
    
    echo ""
    read -rp "🔹 Введите Fake TLS домен [yastatic.net]: " FAKE_TLS_DOMAIN
    FAKE_TLS_DOMAIN=\${FAKE_TLS_DOMAIN:-yastatic.net}
    log_ok "Fake TLS домен: \$FAKE_TLS_DOMAIN"
    
    echo ""
    read -rp "🔹 Введите домен для ссылки (Enter = IP сервера): " PROXY_DOMAIN
    if [[ -z "\$PROXY_DOMAIN" ]]; then
        PROXY_DOMAIN=\$(get_server_ip)
        log_info "Будет использован IP: \$PROXY_DOMAIN"
    else
        log_ok "Домен: \$PROXY_DOMAIN"
    fi
}

# Генерация секрета
generate_secret() {
    log_info "Генерация секретного ключа..."
    SECRET=\$(docker run --rm nineseconds/mtg:2 generate-secret --hex "\$FAKE_TLS_DOMAIN")
    log_ok "Секрет сгенерирован"
}

# Запуск контейнера
run_proxy() {
    log_info "Запуск MTProxy контейнера..."
    docker run -d \\
        --name telegram \\
        --restart unless-stopped \\
        -p "\$PROXY_PORT":8443 \\
        nineseconds/mtg:2 \\
        simple-run -n 1.1.1.1 -i prefer-ipv4 0.0.0.0:8443 "\$SECRET" >/dev/null 2>&1
    sleep 2
    if docker ps | grep -q telegram; then
        log_ok "Контейнер запущен"
    else
        log_error "Не удалось запустить контейнер"
        exit 1
    fi
}

# Вывод результата
show_result() {
    echo ""
    echo -e "\${GREEN}╔════════════════════════════════════════╗\${NC}"
    echo -e "\${GREEN}║  🎉 Прокси готов к использованию!      ║\${NC}"
    echo -e "\${GREEN}╚════════════════════════════════════════╝\${NC}"
    echo ""
    echo -e "\${YELLOW}📋 Ссылка для Telegram:\${NC}"
    echo "https://t.me/proxy?server=\$PROXY_DOMAIN&port=\$PROXY_PORT&secret=\$SECRET"
    echo ""
    echo -e "\${YELLOW}💡 Как подключить:\${NC}"
    echo "  1. Скопируйте ссылку выше"
    echo "  2. Откройте её в Telegram"
    echo "  3. Нажмите «Добавить прокси»"
    echo "  4. Проверьте: Настройки → Данные и память → Прокси → ✅"
    echo ""
    echo -e "\${BLUE}🔧 Полезные команды:\${NC}"
    echo "  docker logs --tail 50 telegram   # посмотреть логи"
    echo "  docker restart telegram          # перезапустить"
    echo "  docker stop telegram && docker rm telegram  # удалить"
    echo ""
}

# Сохранение секрета в файл
save_secret() {
    echo "\$SECRET" > ~/mtproxy_secret.txt
    chmod 600 ~/mtproxy_secret.txt
    log_info "Секрет сохранён в ~/mtproxy_secret.txt"
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
`;

    // ✅ Отдаём скрипт с правильными заголовками
    return new Response(installerScript, {
      status: 200,
      headers: {
        'Content-Type': 'application/x-sh; charset=utf-8',
        'Content-Disposition': 'inline; filename="install.sh"',
        'Cache-Control': 'no-cache, no-store, must-revalidate',
        'X-Content-Type-Options': 'nosniff',
        'X-Frame-Options': 'DENY'
      }
    });
  }
};
