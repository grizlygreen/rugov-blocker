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
for pkg in ipset iptables-persistent wget curl; do
    if ! command -v "${pkg%%-*}" &>/dev/null && ! dpkg -s "$pkg" &>/dev/null 2>&1; then
        warn "Установка $pkg..."
        apt-get install -y "$pkg" -qq
        ok "$pkg установлен"
    else
        ok "$pkg — есть"
    fi
done

echo

# Скопировать скрипт
mkdir -p "$APP_DIR"
cp "$SCRIPT_DIR/rugov-update.sh" "$APP_DIR/rugov-update.sh"
chmod +x "$APP_DIR/rugov-update.sh"
ok "Скрипт установлен в $APP_DIR/rugov-update.sh"

# Telegram
echo
echo "Настройка Telegram-уведомлений"
echo "(нужен бот — создай через @BotFather если нет)"
echo
read -rp "Вставь Telegram Bot Token (или Enter чтобы пропустить): " tg_token

if [[ -n "$tg_token" ]]; then
    read -rp "Вставь Chat ID: " tg_chat_id
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
        source "$APP_DIR/telegram.conf"
        curl -s -X POST "https://api.telegram.org/bot${TG_TOKEN}/sendMessage" \
            --data-urlencode "chat_id=${TG_CHAT_ID}" \
            --data-urlencode "text=✅ Блокировщик РКН установлен и настроен" \
            -o /dev/null && ok "Тестовое сообщение отправлено"
    fi
else
    warn "Telegram пропущен — уведомлений не будет"
fi

# Cron — ежедневно в 04:00
echo
echo "0 4 * * * root $APP_DIR/rugov-update.sh" > /etc/cron.d/rugov-update
chmod 644 /etc/cron.d/rugov-update
ok "Cron настроен: обновление каждый день в 04:00"

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
