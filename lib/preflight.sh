#!/usr/bin/env bash
# =================================================================
# lib/preflight.sh — Preflight проверки окружения
#
# Вызываются из install.sh ДО load_modules().
# Каждая функция: 0=OK, ненулевой=FAIL, критическое → die().
# Зависит от: lib/bootstrap.sh (log_*, die, warn)
# =================================================================

# -----------------------------------------------------------------
# Root
# -----------------------------------------------------------------
check_root() {
    [[ "$EUID" -eq 0 ]] || die "Запустите от имени root (sudo bash install.sh)"
    log_ok "Root: EUID=$EUID"
}

# -----------------------------------------------------------------
# ОС — определяет PKG_MGR для использования внутри preflight
# НЕ устанавливает PACKAGE_MANAGEMENT_* — это делает modules/core.sh::identifyOS()
# -----------------------------------------------------------------
check_os() {
    if command -v apt &>/dev/null; then
        PKG_MGR="apt"
    elif command -v dnf &>/dev/null; then
        PKG_MGR="dnf"
    elif command -v yum &>/dev/null; then
        PKG_MGR="yum"
    else
        die "Поддерживаются только системы с apt / dnf / yum"
    fi
    export PKG_MGR
    log_ok "OS check: PKG_MGR=$PKG_MGR"
}

# -----------------------------------------------------------------
# Свободное место
# -----------------------------------------------------------------
check_disk_space() {
    local required="${1:-1536}"
    local free_mb; free_mb=$(df -m / | awk 'NR==2{print $4}')
    (( free_mb >= required )) \
        || die "Мало места: ${free_mb} МБ (нужно минимум ${required} МБ)"
    log_ok "Диск: ${free_mb} МБ свободно"
}

# -----------------------------------------------------------------
# Интернет
# -----------------------------------------------------------------
check_internet() {
    local ok=false
    local hosts=(1.1.1.1 8.8.8.8 github.com)
    for h in "${hosts[@]}"; do
        if curl -fsS --connect-timeout 5 --max-time 8 \
                -o /dev/null "https://${h}" 2>/dev/null; then
            ok=true; break
        fi
    done
    $ok || die "Нет доступа к интернету. Проверьте сетевые настройки."
    log_ok "Интернет: OK"
}

# -----------------------------------------------------------------
# GitHub репозиторий
# -----------------------------------------------------------------
check_repo_access() {
    local url="${VWN_GITHUB_RAW}/install.sh"
    if curl -fsS --connect-timeout 10 --max-time 15 \
            -o /dev/null "$url" 2>/dev/null; then
        log_ok "GitHub: OK"
        return 0
    fi
    log_warn "GitHub недоступен напрямую: $url"
    return 1
}

# -----------------------------------------------------------------
# Запуск всех проверок перед установкой
# -----------------------------------------------------------------
run_preflight_checks() {
    section "Проверка окружения"
    step     "Root-права"              check_root
    step     "Определение ОС"          check_os
    step     "Свободное место (≥1.5 ГБ)" check_disk_space "$VWN_MIN_DISK_MB"
    step     "Интернет"                check_internet
    soft_step "GitHub-репозиторий"     check_repo_access
}
