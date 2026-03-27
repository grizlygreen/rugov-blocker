#!/bin/bash
# rugov-update.sh — обновление списка блокировок РКН через ipset
# CPU-friendly: использует ipset restore вместо построчного добавления

set -euo pipefail

# ── Конфигурация ────────────────────────────────────────────────────────────
APP_DIR="/etc/rugov"
[[ -f "$APP_DIR/server.conf" ]] && source "$APP_DIR/server.conf"
SERVER_NAME="${RUGOV_SERVER_NAME:-$(hostname -s)}"
BLACKLIST_URL="https://github.com/C24Be/AS_Network_List/raw/main/blacklists/blacklist.txt"
SETNAME_V4="rugov_v4"
SETNAME_V6="rugov_v6"
TMP_V4="${SETNAME_V4}_tmp"
TMP_V6="${SETNAME_V6}_tmp"
LOG="$APP_DIR/update.log"
BLACKLIST_FILE="$APP_DIR/blacklist.txt"
CONFIG="$APP_DIR/telegram.conf"
# ────────────────────────────────────────────────────────────────────────────

log() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') $*" | tee -a "$LOG"
}

send_telegram() {
    [[ ! -f "$CONFIG" ]] && return 0
    # shellcheck source=/dev/null
    source "$CONFIG"
    [[ -z "${TG_TOKEN:-}" || -z "${TG_CHAT_ID:-}" ]] && return 0
    curl -s -X POST "https://api.telegram.org/bot${TG_TOKEN}/sendMessage" \
        --data-urlencode "chat_id=${TG_CHAT_ID}" \
        --data-urlencode "text=$1" \
        --data-urlencode "parse_mode=HTML" \
        -o /dev/null
}

ensure_ipsets() {
    for ver in 4 6; do
        local setname="rugov_v${ver}"
        local family="inet"; [[ $ver -eq 6 ]] && family="inet6"
        local ipcmd="iptables"; [[ $ver -eq 6 ]] && ipcmd="ip6tables"

        if ! ipset list "$setname" &>/dev/null; then
            ipset create "$setname" hash:net family "$family" maxelem 500000
            "$ipcmd" -t raw -A PREROUTING \
                -m set --match-set "$setname" src -j DROP
            log "Создан ipset $setname + правило DROP"
        fi
    done
}

download_blacklist() {
    local tmp="${BLACKLIST_FILE}.tmp"
    if ! wget -q --timeout=30 -O "$tmp" "$BLACKLIST_URL"; then
        log "ОШИБКА: не удалось скачать blacklist"
        return 1
    fi
    mv "$tmp" "$BLACKLIST_FILE"
}

# Ключевая оптимизация: ipset restore вместо построчного добавления
populate_sets() {
    local count_v4=0 count_v6=0

    # Подготовить restore-файл для IPv4
    local restore_v4
    restore_v4=$(
        echo "create ${TMP_V4} hash:net family inet maxelem 500000 -exist"
        awk -v s="${TMP_V4}" \
            '!/^[[:space:]]*$/ && !/^#/ && !/:/ { print "add " s " " $1 }' \
            "$BLACKLIST_FILE"
    )

    # Подготовить restore-файл для IPv6
    local restore_v6
    restore_v6=$(
        echo "create ${TMP_V6} hash:net family inet6 maxelem 500000 -exist"
        awk -v s="${TMP_V6}" \
            '!/^[[:space:]]*$/ && !/^#/ && /:/ { print "add " s " " $1 }' \
            "$BLACKLIST_FILE"
    )

    # Загрузить одним вызовом (быстро, без fork на каждую строку)
    echo "$restore_v4" | ipset restore -!
    echo "$restore_v6" | ipset restore -!

    count_v4=$(echo "$restore_v4" | grep -c "^add " || true)
    count_v6=$(echo "$restore_v6" | grep -c "^add " || true)

    # Атомарная замена — нет разрыва в защите
    ipset swap "${TMP_V4}" "${SETNAME_V4}"
    ipset swap "${TMP_V6}" "${SETNAME_V6}"
    ipset destroy "${TMP_V4}" 2>/dev/null || true
    ipset destroy "${TMP_V6}" 2>/dev/null || true

    echo "$count_v4 $count_v6"
}

main() {
    [[ "$(id -u)" != "0" ]] && { echo "Нужен root" >&2; exit 1; }
    mkdir -p "$APP_DIR"

    log "Запуск обновления..."

    ensure_ipsets

    if ! download_blacklist; then
        send_telegram "❌ <b>РКН блокировки</b>: ошибка загрузки списка"
        exit 1
    fi

    read -r count_v4 count_v6 < <(populate_sets)

    # Сохранить правила
    ipset save > /etc/iptables/ipset.rules 2>/dev/null || true
    iptables-save  > /etc/iptables/rules.v4 2>/dev/null || true

    log "Готово: IPv4=${count_v4}, IPv6=${count_v6}"

    send_telegram "✅ <b>РКН блокировки обновлены</b> [<code>${SERVER_NAME}</code>]
📋 IPv4: <code>${count_v4}</code> сетей
📋 IPv6: <code>${count_v6}</code> сетей
🕐 $(date '+%d.%m.%Y %H:%M')"
}

main
