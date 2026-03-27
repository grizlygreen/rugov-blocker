#!/bin/bash
# rugov-report.sh — ежедневный отчёт о попытках подключения из заблокированных сетей РКН
# Запускается по cron раз в сутки

set -euo pipefail

APP_DIR="/etc/rugov"
CONFIG="$APP_DIR/telegram.conf"
LOG_TAG="RUGOV_SCAN"
[[ -f "$APP_DIR/server.conf" ]] && source "$APP_DIR/server.conf"
SERVER_NAME="${RUGOV_SERVER_NAME:-$(hostname -s)}"

# ── Убедиться что LOG-правила существуют ────────────────────────────────────
ensure_log_rules() {
    # Добавляем LOG перед DROP только если ещё нет
    for ver in 4 6; do
        local setname="rugov_v${ver}"
        local ipcmd="iptables"; [[ $ver -eq 6 ]] && ipcmd="ip6tables"

        # Проверяем есть ли уже LOG правило
        if ! "$ipcmd" -t raw -C PREROUTING \
            -m set --match-set "$setname" src \
            -m limit --limit 5/min --limit-burst 10 \
            -j LOG --log-prefix "${LOG_TAG}: " 2>/dev/null; then

            # Вставляем LOG перед существующим DROP (в позицию 1, DROP сдвинется на 2)
            "$ipcmd" -t raw -I PREROUTING 1 \
                -m set --match-set "$setname" src \
                -m limit --limit 5/min --limit-burst 10 \
                -j LOG --log-prefix "${LOG_TAG}: " 2>/dev/null || true
        fi
    done
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

# ── Парсинг логов за последние 24 часа ──────────────────────────────────────
parse_logs() {
    # Ищем в kernel log (dmesg/syslog/kern.log)
    local log_sources=()
    [[ -f /var/log/kern.log ]]   && log_sources+=(/var/log/kern.log)
    [[ -f /var/log/syslog ]]     && log_sources+=(/var/log/syslog)
    [[ -f /var/log/messages ]]   && log_sources+=(/var/log/messages)

    if [[ ${#log_sources[@]} -eq 0 ]]; then
        # Попробовать journalctl
        journalctl -k --since "24 hours ago" 2>/dev/null | grep "${LOG_TAG}" || true
        return
    fi

    # Последние 24 часа (grep по временной метке — берём всё за сегодня и вчера)
    local yesterday today
    yesterday=$(date -d 'yesterday' '+%b %e' 2>/dev/null || date -v-1d '+%b %e' 2>/dev/null || echo "")
    today=$(date '+%b %e')

    grep -h "${LOG_TAG}" "${log_sources[@]}" 2>/dev/null | \
        grep -E "^($today|$yesterday)" || true
}

build_report() {
    local raw_log
    raw_log=$(parse_logs)

    local total_hits=0
    local unique_ips=0
    local top_ips=""
    local top_ports=""

    if [[ -n "$raw_log" ]]; then
        total_hits=$(echo "$raw_log" | wc -l)

        # Уникальные IP источников
        unique_ips=$(echo "$raw_log" | grep -oP 'SRC=\K[\d.]+' | sort -u | wc -l)

        # Топ-5 IP по количеству попыток
        top_ips=$(echo "$raw_log" | grep -oP 'SRC=\K[\d.]+' | sort | uniq -c | sort -rn | head -5 | \
            awk '{printf "  <code>%-15s</code> %s раз\n", $2, $1}')

        # Топ-5 портов назначения
        top_ports=$(echo "$raw_log" | grep -oP 'DPT=\K\d+' | sort | uniq -c | sort -rn | head -5 | \
            awk '{printf "  порт <code>%s</code> — %s раз\n", $2, $1}')
    fi

    echo "$total_hits|$unique_ips|$top_ips|$top_ports"
}

main() {
    [[ "$(id -u)" != "0" ]] && { echo "Нужен root" >&2; exit 1; }

    ensure_log_rules

    local report
    report=$(build_report)

    IFS='|' read -r total unique top_ips top_ports <<< "$report"

    local msg
    if [[ "$total" -eq 0 ]]; then
        msg="📊 <b>РКН сканирование</b> [<code>${SERVER_NAME}</code>]
За последние 24 ч: <b>0 попыток</b> из заблокированных сетей
🕐 $(date '+%d.%m.%Y %H:%M')"
    else
        msg="📊 <b>РКН сканирование</b> [<code>${SERVER_NAME}</code>]
За последние 24 ч: <b>${total} попыток</b> с <b>${unique}</b> уникальных IP

🔴 <b>Топ источников:</b>
${top_ips:-  нет данных}

🎯 <b>Целевые порты:</b>
${top_ports:-  нет данных}

🕐 $(date '+%d.%m.%Y %H:%M')"
    fi

    send_telegram "$msg"
}

main
