#!/bin/bash
# rugov-install.sh — установка блокировки сетей РКН
# Использование: bash rugov-install.sh

set -euo pipefail

APP_DIR="/etc/rugov"
SCRIPT_DIR="$(dirname "$(readlink -f "$0")")"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'

ok()   { echo -e "${GREEN}✓${NC} $*"; }
warn() { echo -e "${YELLOW}!${NC} $*"; }
err()  { echo -e "${RED}✗${NC} $*" >&2; exit 1; }

[[ "$(id -u)" != "0" ]] && err "Запусти от root: sudo bash $0"

echo "═══════════════════════════════════════"
echo "  Установка блокировщика сетей РКН"
echo "═══════════════════════════════════════"
echo

# Миграция со старого скрипта
migrate_old() {
    local OLD_DIR="/var/log/rugov_blacklist"
    local OLD_CRON_DAILY="/etc/cron.daily/rugov_updater"
    local OLD_CRON_D="/etc/cron.d/rugov_telegram_notifier"
    local migrated=0

    if [[ -f "$OLD_CRON_DAILY" ]]; then
        rm -f "$OLD_CRON_DAILY"
        ok "Удалён старый cron: $OLD_CRON_DAILY"
        ((migrated++))
    fi
    if [[ -f "$OLD_CRON_D" ]]; then
        rm -f "$OLD_CRON_D"
        ok "Удалён старый cron: $OLD_CRON_D"
        ((migrated++))
    fi

    # Telegram конфиг — перенести если есть
    if [[ -f "$OLD_DIR/telegram.conf" && ! -f "$APP_DIR/telegram.conf" ]]; then
        mkdir -p "$APP_DIR"
        # Конвертируем старый формат (TELEGRAM_TOKEN) в новый (TG_TOKEN)
        source "$OLD_DIR/telegram.conf"
        cat > "$APP_DIR/telegram.conf" << EOF
TG_TOKEN="${TELEGRAM_TOKEN:-}"
TG_CHAT_ID="${TELEGRAM_CHAT_ID:-}"
EOF
        chmod 600 "$APP_DIR/telegram.conf"
        ok "Telegram-конфиг перенесён из $OLD_DIR"
        ((migrated++))
    fi

    if [[ -d "$OLD_DIR" ]]; then
        rm -rf "$OLD_DIR"
        ok "Удалена старая директория: $OLD_DIR"
        ((migrated++))
    fi

    [[ $migrated -gt 0 ]] && warn "Миграция со старой версии выполнена"
    return 0
}

if [[ -f "/var/log/rugov_blacklist/updater.sh" ]] || [[ -f "/etc/cron.daily/rugov_updater" ]]; then
    echo
    warn "Обнаружена старая версия скрипта — выполняю миграцию..."
    migrate_old
    echo
fi

# Зависимости
for pkg in ipset wget curl; do
    if ! command -v "${pkg%%-*}" &>/dev/null && ! dpkg -s "$pkg" &>/dev/null 2>&1; then
        warn "Установка $pkg..."
        apt-get install -y "$pkg" -qq
        ok "$pkg установлен"
    else
        ok "$pkg — есть"
    fi
done

# iptables-persistent — только если UFW не установлен (конфликт пакетов)
if dpkg -s ufw &>/dev/null 2>&1; then
    ok "UFW обнаружен — iptables-persistent пропускаем (совместимы)"
    # Восстановление ipset при перезагрузке через @reboot cron
    REBOOT_LINE="@reboot root ipset restore -! < /etc/iptables/ipset.rules 2>/dev/null || true"
    grep -qF "ipset restore" /etc/cron.d/rugov-update 2>/dev/null || true
else
    if ! dpkg -s iptables-persistent &>/dev/null 2>&1; then
        warn "Установка iptables-persistent..."
        DEBIAN_FRONTEND=noninteractive apt-get install -y iptables-persistent -qq
        ok "iptables-persistent установлен"
    else
        ok "iptables-persistent — есть"
    fi
fi

echo

# Загрузить существующий конфиг если есть (обновление)
existing_srv=""
existing_token=""
existing_chat=""
IS_UPDATE=false

if [[ -f "$APP_DIR/server.conf" ]]; then
    source "$APP_DIR/server.conf"
    existing_srv="${RUGOV_SERVER_NAME:-}"
    IS_UPDATE=true
fi
if [[ -f "$APP_DIR/telegram.conf" ]]; then
    source "$APP_DIR/telegram.conf"
    existing_token="${TG_TOKEN:-}"
    existing_chat="${TG_CHAT_ID:-}"
fi

if $IS_UPDATE; then
    warn "Обнаружена существующая установка — режим обновления"
    echo "  Текущее имя сервера: ${existing_srv:-не задано}"
    echo "  Telegram: ${existing_token:+настроен}"
    echo
fi

# Имя сервера
default_srv="${existing_srv:-$(hostname -s)}"
read -rp "Имя сервера для уведомлений (Enter = ${default_srv}): " srv_name
srv_name="${srv_name:-${default_srv}}"

# Скопировать скрипты
mkdir -p "$APP_DIR"
cp "$SCRIPT_DIR/rugov-update.sh" "$APP_DIR/rugov-update.sh"
cp "$SCRIPT_DIR/rugov-report.sh" "$APP_DIR/rugov-report.sh"
chmod +x "$APP_DIR/rugov-update.sh" "$APP_DIR/rugov-report.sh"

# Сохранить имя сервера
echo "RUGOV_SERVER_NAME=\"${srv_name}\"" > "$APP_DIR/server.conf"
ok "Скрипты обновлены в $APP_DIR/"
ok "Имя сервера: ${srv_name}"

# Telegram
echo
echo "Настройка Telegram-уведомлений"
if [[ -n "$existing_token" ]]; then
    echo "(токен уже сохранён — Enter чтобы оставить без изменений)"
else
    echo "(нужен бот — создай через @BotFather если нет)"
fi
echo
read -rp "Telegram Bot Token (Enter = оставить): " tg_token
tg_token="${tg_token:-${existing_token}}"

if [[ -n "$tg_token" ]]; then
    read -rp "Chat ID (Enter = оставить): " tg_chat_id
    tg_chat_id="${tg_chat_id:-${existing_chat}}"

    cat > "$APP_DIR/telegram.conf" << EOF
TG_TOKEN="${tg_token}"
TG_CHAT_ID="${tg_chat_id}"
EOF
    chmod 600 "$APP_DIR/telegram.conf"
    ok "Telegram настроен"

    # Тест
    read -rp "Отправить тестовое сообщение? (y/n) " -n 1 -r
    echo
    if [[ "$REPLY" =~ ^[Yy]$ ]]; then
        curl -s -X POST "https://api.telegram.org/bot${tg_token}/sendMessage" \
            --data-urlencode "chat_id=${tg_chat_id}" \
            --data-urlencode "text=✅ Блокировщик РКН ${IS_UPDATE:+обновлён}${IS_UPDATE:-установлен} на [${srv_name}]" \
            -o /dev/null && ok "Тестовое сообщение отправлено"
    fi
else
    warn "Telegram пропущен — уведомлений не будет"
fi

# Cron
echo
cat > /etc/cron.d/rugov-update << EOF
# Обновление списков РКН — ежедневно в 04:00
0 4 * * * root . /etc/rugov/server.conf && /etc/rugov/rugov-update.sh
# Отчёт о сканировании — ежедневно в 08:00
0 8 * * * root . /etc/rugov/server.conf && /etc/rugov/rugov-report.sh
# Восстановление ipset после перезагрузки
@reboot root sleep 10 && ipset restore -! < /etc/iptables/ipset.rules 2>/dev/null && . /etc/rugov/server.conf && /etc/rugov/rugov-update.sh
EOF
chmod 644 /etc/cron.d/rugov-update
ok "Cron настроен: обновление в 04:00, отчёт в 08:00"

# Первый запуск
echo
echo "Запуск первоначальной загрузки списков..."
echo "(это займёт 10-30 секунд)"
echo
"$APP_DIR/rugov-update.sh"

echo
echo "═══════════════════════════════════════"
ok "Установка завершена"
echo "  Обновление: $APP_DIR/rugov-update.sh"
echo "  Логи:       $APP_DIR/update.log"
echo "  Cron:       /etc/cron.d/rugov-update"
echo "═══════════════════════════════════════"
