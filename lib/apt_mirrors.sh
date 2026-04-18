#!/usr/bin/env bash
# =================================================================
# lib/apt_mirrors.sh — Автовыбор рабочего APT-зеркала
#
# Вызывается из install.sh в фазе bootstrap (до load_modules).
# После load_modules() используется prepareApt() из modules/core.sh.
# Зависит от: lib/bootstrap.sh
# =================================================================

# -----------------------------------------------------------------
# Убиваем зависшие apt/dpkg процессы и снимаем блокировки
# ВНИМАНИЕ: это bootstrap-версия. Полная — в modules/core.sh::prepareApt()
# -----------------------------------------------------------------
_bootstrap_kill_apt() {
    killall -9 apt apt-get dpkg dpkg-deb unattended-upgrades 2>/dev/null || true
    fuser -kk /var/lib/dpkg/lock* /var/cache/apt/archives/lock \
               /var/lib/apt/lists/lock* 2>/dev/null || true
    sleep 0.5
    rm -f /var/lib/dpkg/lock /var/lib/dpkg/lock-frontend \
          /var/cache/apt/archives/lock /var/lib/apt/lists/lock*
    export DEBIAN_FRONTEND=noninteractive
    dpkg --configure -a --force-confold --force-confdef 2>/dev/null || true
}

_bootstrap_apt_update() {
    timeout 30 apt-get \
        -o Acquire::ForceIPv4=true \
        -o Acquire::http::Timeout=15 \
        update -qq 2>/dev/null
}

# -----------------------------------------------------------------
# Основная функция — пробует зеркала по очереди
# Вызывается один раз в начале установки
# -----------------------------------------------------------------
fix_apt_mirrors() {
    # Для не-apt систем — ничего не делаем
    [[ "${PKG_MGR:-apt}" != "apt" ]] && return 0

    _bootstrap_kill_apt

    # Сначала пробуем стандартный репозиторий
    if _bootstrap_apt_update; then
        log_ok "APT: стандартное зеркало OK"
        return 0
    fi

    warn "APT: основной репозиторий не отвечает, пробуем зеркала..."

    local mirrors=(
        "http://ftp.ru.debian.org/debian/"
        "http://mirror.rol.ru/debian/"
        "http://debian.mirohost.net/debian/"
        "http://debian-mirror.ru/debian/"
        "http://ftp.debian.org/debian/"
    )

    cp -a /etc/apt/sources.list /etc/apt/sources.list.vwn_backup 2>/dev/null || true

    local mirror
    for mirror in "${mirrors[@]}"; do
        printf "  Зеркало %-45s" "$mirror"
        log_info "APT: пробуем $mirror"

        sed -e "s|http://.*debian.org/debian/|${mirror}|g" \
            -e "s|http://security.debian.org/|${mirror}|g" \
            /etc/apt/sources.list > /etc/apt/sources.list.tmp
        mv /etc/apt/sources.list.tmp /etc/apt/sources.list

        _bootstrap_kill_apt
        if _bootstrap_apt_update; then
            echo -e " ${GREEN}[OK]${RESET}"
            log_ok "APT: зеркало OK: $mirror"
            return 0
        else
            echo -e " ${RED}[FAIL]${RESET}"
        fi
    done

    # Откат на оригинал
    mv /etc/apt/sources.list.vwn_backup /etc/apt/sources.list 2>/dev/null || true
    _bootstrap_kill_apt
    warn "APT: все зеркала недоступны, используем стандартный"
}
