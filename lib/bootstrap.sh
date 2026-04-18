#!/usr/bin/env bash
# =================================================================
# lib/bootstrap.sh — Bootstrap-слой установщика
#
# НАЗНАЧЕНИЕ:
#   Предоставляет минимальный UI и логирование для фазы ДО загрузки
#   modules/*.sh. После load_modules() модули переопределяют часть
#   функций (run_task, msg, isRoot и т.д.) — это нормально.
#
# ПРАВИЛА:
#   • Не переопределять функции которые есть в modules/ (run_task,
#     identifyOS, installPackage, prepareApt, getServerIP, и т.д.)
#   • Не устанавливать IFS глобально — это сломает все модули
#   • Не объявлять readonly переменные которые modules/ переопределяют
# =================================================================

# -----------------------------------------------------------------
# ЦВЕТА — инициализируются один раз
# Экспортируем оба варианта: CAPS (наш стиль) и lowercase (стиль modules/)
# -----------------------------------------------------------------
_bootstrap_init_colors() {
    if [[ -t 1 ]] && command -v tput &>/dev/null; then
        RED=$(tput setaf 1 2>/dev/null; tput bold 2>/dev/null) || RED=''
        GREEN=$(tput setaf 2 2>/dev/null; tput bold 2>/dev/null) || GREEN=''
        YELLOW=$(tput setaf 3 2>/dev/null; tput bold 2>/dev/null) || YELLOW=''
        CYAN=$(tput setaf 6 2>/dev/null; tput bold 2>/dev/null) || CYAN=''
        RESET=$(tput sgr0 2>/dev/null) || RESET=''
    else
        RED='' GREEN='' YELLOW='' CYAN='' RESET=''
    fi

    # Lowercase-алиасы — для совместимости с modules/*.sh
    # (lang.sh, core.sh, security.sh и др. используют $red/$green/$reset)
    red="$RED"; green="$GREEN"; yellow="$YELLOW"
    cyan="$CYAN"; reset="$RESET"

    export RED GREEN YELLOW CYAN RESET
    export red green yellow cyan reset
}
_bootstrap_init_colors

# -----------------------------------------------------------------
# ЛОГИРОВАНИЕ — единственное место записи в лог
# LOG_FILE передаётся из install.sh как обычная переменная (не readonly)
# -----------------------------------------------------------------
_log() {
    local level="$1"; shift
    local ts; ts=$(date '+%H:%M:%S' 2>/dev/null || echo '??:??:??')
    printf '[%s] [%-5s] %s\n' "$ts" "$level" "$*" >> "${LOG_FILE:-/var/log/vwn_install.log}" 2>/dev/null || true
}

log_info()  { _log "INFO " "$@"; }
log_ok()    { _log "OK   " "$@"; }
log_warn()  { _log "WARN " "$@"; }
log_error() { _log "ERROR" "$@"; }

# -----------------------------------------------------------------
# ВЫВОД — с одновременной записью в лог
# -----------------------------------------------------------------
info()  { echo -e "${CYAN}$*${RESET}";   log_info  "$*"; }
ok()    { echo -e "${GREEN}$*${RESET}";  log_ok    "$*"; }
warn()  { echo -e "${YELLOW}$*${RESET}"; log_warn  "$*"; }
err()   { echo -e "${RED}$*${RESET}" >&2; log_error "$*"; }
die()   { err "ОШИБКА: $*"; exit 1; }

# -----------------------------------------------------------------
# STEP — запускает команду с индикатором [OK] / [FAIL]
# Используется только в install.sh. После load_modules() модули
# используют свой run_task() с другим форматом — это ОК, они
# работают в своём контексте (интерактивное меню).
# -----------------------------------------------------------------
step() {
    local desc="$1"; shift
    printf "  %-52s" "$desc"
    log_info "STEP: ${desc}"

    local output rc=0
    output=$("$@" 2>&1) || rc=$?

    if (( rc == 0 )); then
        echo -e " ${GREEN}[OK]${RESET}"
        log_ok "  → OK"
    else
        echo -e " ${RED}[FAIL]${RESET}"
        log_error "  → FAIL rc=${rc}: ${output}"
        return $rc
    fi
}

# Non-fatal вариант — SKIP вместо FAIL
soft_step() {
    local desc="$1"; shift
    printf "  %-52s" "$desc"
    log_info "SOFT: ${desc}"

    if "$@" &>/dev/null; then
        echo -e " ${GREEN}[OK]${RESET}"
        log_ok "  → OK"
    else
        echo -e " ${YELLOW}[SKIP]${RESET}"
        log_warn "  → SKIP (non-fatal)"
    fi
}

# -----------------------------------------------------------------
# SECTION — визуальный разделитель этапов
# -----------------------------------------------------------------
section() {
    echo ""
    echo -e "${CYAN}━━━ $* ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
    log_info "=== SECTION: $* ==="
}

# -----------------------------------------------------------------
# MSG — fallback до загрузки modules/lang.sh
# После load_modules() → _initLang() заполняет MSG[] и msg() из
# modules/lang.sh начинает работать нормально.
# ВАЖНО: мы НЕ переопределяем msg() после load_modules — lang.sh
# делает это сам через объявление функции поверх нашей.
# -----------------------------------------------------------------
msg() {
    # Если lang.sh уже загружен и заполнил MSG[] — используем его
    if declare -p MSG &>/dev/null 2>&1 && [[ -n "${MSG[${1:-}]+x}" ]]; then
        echo "${MSG[$1]}"
        return
    fi

    # Fallback-таблица (минимум для фазы bootstrap)
    case "${1:-}" in
        run_as_root)      echo "Run as root!" ;;
        os_unsupported)   echo "Only apt/dnf/yum systems supported." ;;
        install_deps)     echo "Installing dependencies..." ;;
        install_modules)  echo "Downloading modules..." ;;
        install_vwn)      echo "Installing vwn binary..." ;;
        install_title)    echo "VWN — Xray VLESS + WARP + CDN + Reality" ;;
        update_title)     echo "VWN — Updating modules" ;;
        update_done)      echo "Update complete! Version" ;;
        install_done)     echo "Modules installed in" ;;
        install_version)  echo "Version" ;;
        launching_menu)   echo "Launching setup menu..." ;;
        module_fail)      echo "Failed to download" ;;
        auto_done)        echo "Unattended installation complete!" ;;
        run_vwn)          echo "Run: vwn" ;;
        yes_no)           echo "(y/n)" ;;
        press_enter)      echo "Press Enter..." ;;
        choose)           echo "Choice: " ;;
        back)             echo "Back" ;;
        cancel)           echo "Cancelled." ;;
        done)             echo "Done." ;;
        error)            echo "Error" ;;
        invalid)          echo "Invalid input!" ;;
        invalid_port)     echo "Invalid port." ;;
        no_logs)          echo "No logs" ;;
        restarted)        echo "Restarted." ;;
        removed)          echo "Removed." ;;
        swap_creating)    echo "Creating swap file" ;;
        swap_created)     echo "Swap created:" ;;
        swap_fail)        echo "Swap creation failed, continuing..." ;;
        installed_in)     echo "installed in" ;;
        *)                echo "${1:-}" ;;
    esac
}
