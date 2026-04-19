#!/bin/bash
# =================================================================
# nginx.sh — Nginx конфиг, CDN, SSL сертификаты
#
# Два режима:
#   base   — WS+TLS на 443 (Nginx напрямую с SSL)
#   vision — Vision на 443 (Nginx на 7443 без SSL, fallback)
# =================================================================

VWN_CONFIG_DIR="${VWN_CONFIG_DIR:-/usr/local/lib/vwn/config}"

_getCountryCode() {
    local ip="$1"
    local code
    code=$(curl -s --connect-timeout 5 "http://ip-api.com/line/${ip}?fields=countryCode" 2>/dev/null | tr -d '[:space:]')
    if [[ "$code" =~ ^[A-Z]{2}$ ]]; then
        echo "[$code]"
    else
        echo "[??]"
    fi
}

setNginxCert() {
    [ ! -d '/etc/nginx/cert' ] && mkdir -p '/etc/nginx/cert'
    if [ ! -f /etc/nginx/cert/default.crt ]; then
        openssl req -x509 -nodes -days 3650 -newkey rsa:2048 \
            -keyout /etc/nginx/cert/default.key \
            -out /etc/nginx/cert/default.crt \
            -subj "/CN=localhost" &>/dev/null
    fi
}

# ── Режим BASE: WS+TLS на 443 напрямую ──────────────────────────


writeNginxConfigBase() {
    local xrayPort="$1" domain="$2" proxyUrl="$3" wsPath="$4"
    local proxy_host=""
    proxy_host=$(echo "$proxyUrl" | sed 's|https://||;s|http://||;s|/.*||')

    setNginxCert

    # nginx.conf — общая часть
    cp "$VWN_CONFIG_DIR/nginx_main.conf" /etc/nginx/nginx.conf

    # default.conf
    cp "$VWN_CONFIG_DIR/nginx_default.conf" /etc/nginx/conf.d/default.conf

    # xray.conf — WS server block
    render_config "$VWN_CONFIG_DIR/nginx_base.conf" "$nginxPath" \
        DOMAIN "$domain" XRAY_PORT "$xrayPort" WS_PATH "$wsPath" \
        PROXY_URL "$proxyUrl" PROXY_HOST "$proxy_host"

    vwn_conf_set STUB_URL "$proxyUrl"
    vwn_conf_set NGINX_MODE "base"
    vwn_conf_set DOMAIN    "$domain"

    setupRealIpRestore
    _writeSubMapConf
}

# ── Режим VISION: Vision на 443, Nginx fallback на 7443 без SSL ──

writeNginxConfigVision() {
    local proxyUrl="$1" visionDomain="$2"
    local proxy_host wsPath
    proxy_host=$(echo "$proxyUrl" | sed 's|https://||;s|http://||;s|/.*||')
    # wsPath берётся из уже записанного xray конфига (xhttp или ws)
    wsPath=$(jq -r '.inbounds[0].streamSettings.xhttpSettings.path // .inbounds[0].streamSettings.wsSettings.path // ""' "$configPath" 2>/dev/null)

    setNginxCert

    # nginx.conf — общая часть
    cp "$VWN_CONFIG_DIR/nginx_main.conf" /etc/nginx/nginx.conf

    # В Vision режиме default.conf не нужен — nginx_vision.conf уже содержит
    # listen 80 default_server с редиректом на https. Удаляем чтобы не было
    # "duplicate default server" конфликта.
    rm -f /etc/nginx/conf.d/default.conf

    # xray.conf — Vision fallback server block (HTTP, без SSL!)
    render_config "$VWN_CONFIG_DIR/nginx_vision.conf" "$nginxPath" \
        VISION_DOMAIN "$visionDomain" PROXY_URL "$proxyUrl" PROXY_HOST "$proxy_host" \
        PATH "$wsPath"

    vwn_conf_set STUB_URL "$proxyUrl"
    vwn_conf_set NGINX_MODE "vision"

    _writeSubMapConf
}

# ── Утилиты ──────────────────────────────────────────────────────────────────

_writeSubMapConf() {
    local server_ip country_code
    server_ip=$(getServerIP 2>/dev/null || curl -s --connect-timeout 5 ifconfig.me)
    country_code=$(_getCountryCode "$server_ip")
    render_config "$VWN_CONFIG_DIR/sub_map.conf" /etc/nginx/conf.d/sub_map.conf \
        COUNTRY "$country_code"
}

setupRealIpRestore() {
    echo -e "${cyan}$(msg cf_ips_setup)${reset}"
    local tmp
    tmp=$(mktemp) || return 0

    printf '# Cloudflare real IP restore — auto-generated\n' > "$tmp"

    local ok=0
    for t in v4 v6; do
        local result
        result=$(curl -fsSL --connect-timeout 10 "https://www.cloudflare.com/ips-$t" 2>/dev/null) || continue
        while IFS= read -r ip; do
            [ -z "$ip" ] && continue
            echo "set_real_ip_from $ip;" >> "$tmp"
            ok=1
        done < <(echo "$result" | grep -E '^[0-9a-fA-F:.]+(/[0-9]+)?$')
    done

    if [ "$ok" -eq 0 ]; then
        echo "${yellow}Warning: Could not fetch Cloudflare IPs, skipping real_ip_restore${reset}"
        rm -f "$tmp"
        return 0
    fi

    printf 'real_ip_header CF-Connecting-IP;\nreal_ip_recursive on;\n' >> "$tmp"

    mkdir -p /etc/nginx/conf.d
    mv -f "$tmp" /etc/nginx/conf.d/real_ip_restore.conf
    echo "${green}$(msg cf_ips_ok)${reset}"
}

_manageSubAuth() {
    echo ""
    echo "${cyan}=== $(msg sub_auth_manage) ===${reset}"
    local auth_active=false
    grep -q "auth_basic" "$nginxPath" 2>/dev/null && auth_active=true
    local cur_user cur_pass
    cur_user=$(vwn_conf_get SUB_AUTH_USER)
    cur_pass=$(vwn_conf_get SUB_AUTH_PASS)
    if $auth_active; then
        echo "$(msg sub_auth_status): ${green}$(msg sub_auth_on)${reset}"
        [ -n "$cur_user" ] && echo "$(msg sub_auth_current): ${green}${cur_user}${reset} / ${green}${cur_pass}${reset}"
    else
        echo "$(msg sub_auth_status): ${red}$(msg sub_auth_off)${reset}"
    fi
    echo "${yellow}$(msg sub_auth_warn)${reset}"
    echo ""
    if $auth_active; then
        echo -e "  ${green}1.${reset} $(msg sub_auth_change_pass)"
        echo -e "  ${green}2.${reset} $(msg sub_auth_disable)"
        echo -e "  ${green}0.${reset} $(msg back)"
        read -rp "$(msg choose) " sa_choice
        case "$sa_choice" in
            1) _subAuthSetCredentials && nginx -t && systemctl reload nginx ;;
            2) _subAuthDisable ;;
            0) return ;;
            *) echo "${red}$(msg invalid)${reset}" ;;
        esac
    else
        echo -e "  ${green}1.${reset} $(msg sub_auth_enable)"
        echo -e "  ${green}0.${reset} $(msg back)"
        read -rp "$(msg choose) " sa_choice
        case "$sa_choice" in
            1) _subAuthEnable ;;
            0) return ;;
            *) echo "${red}$(msg invalid)${reset}" ;;
        esac
    fi
}

_subAuthEnable() {
    _subAuthSetCredentials || return 1
    if ! grep -q "auth_basic" "$nginxPath" 2>/dev/null; then
        sed -i '/location ~ \^\/sub\//,/}/ { /}/i\        auth_basic           "Restricted";\n        auth_basic_user_file /etc/nginx/conf.d/.htpasswd;
}' "$nginxPath" 2>/dev/null || true
    fi
    nginx -t && systemctl reload nginx
    echo "${green}$(msg sub_auth_enabled): ${cyan}$(vwn_conf_get SUB_AUTH_USER)${reset} / ${cyan}$(vwn_conf_get SUB_AUTH_PASS)${reset}"
}

_subAuthDisable() {
    echo "${yellow}$(msg sub_auth_disable_confirm) $(msg yes_no)${reset}"
    read -r confirm
    [[ "$confirm" != "y" ]] && return
    sed -i '/auth_basic/d' "$nginxPath" 2>/dev/null || true
    rm -f /etc/nginx/conf.d/.htpasswd
    vwn_conf_del SUB_AUTH_USER
    vwn_conf_del SUB_AUTH_PASS
    nginx -t && systemctl reload nginx
    echo "${green}$(msg sub_auth_disabled)${reset}"
}

_subAuthSetCredentials() {
    local cur_user
    cur_user=$(vwn_conf_get SUB_AUTH_USER)
    read -rp "$(msg sub_auth_new_user) [${cur_user:-vwn}]: " new_user
    new_user="${new_user:-${cur_user:-vwn}}"
    read -rp "$(msg sub_auth_new_pass) ($(msg leave_empty_random)): " new_pass
    [ -z "$new_pass" ] && new_pass=$(openssl rand -base64 12 | tr -d '+/=' | head -c 16)
    local hashed
    hashed=$(python3 -c "
import crypt, sys
u, p = sys.argv[1], sys.argv[2]
print(u + ':' + crypt.crypt(p, crypt.mksalt(crypt.METHOD_SHA512)))
" "$new_user" "$new_pass" 2>/dev/null)
    if [ -n "$hashed" ]; then
        echo "$hashed" > /etc/nginx/conf.d/.htpasswd
        chmod 640 /etc/nginx/conf.d/.htpasswd
        chown root:www-data /etc/nginx/conf.d/.htpasswd 2>/dev/null || true
    fi
    vwn_conf_set SUB_AUTH_USER "$new_user"
    vwn_conf_set SUB_AUTH_PASS "$new_pass"
    echo "${green}$(msg sub_auth_updated): ${cyan}${new_user}${reset} / ${cyan}${new_pass}${reset}"
}

_fetchCfGuardIPs() {
    local tmp
    tmp=$(mktemp) || return 1
    printf '# CF Guard — allow only Cloudflare IPs — auto-generated\ngeo $realip_remote_addr $cloudflare_ip {\n    default 0;\n' > "$tmp"
    local ok=0
    for t in v4 v6; do
        local result
        result=$(curl -fsSL --connect-timeout 10 "https://www.cloudflare.com/ips-$t" 2>/dev/null) || continue
        while IFS= read -r ip; do
            [ -z "$ip" ] && continue
            echo "    $ip 1;" >> "$tmp"
            ok=1
        done < <(echo "$result" | grep -E '^[0-9a-fA-F:.]+(/[0-9]+)?$')
    done
    [ "$ok" -eq 0 ] && { rm -f "$tmp"; echo "${red}$(msg cf_ips_fail)${reset}"; return 1; }
    echo "}" >> "$tmp"
    mkdir -p /etc/nginx/conf.d
    mv -f "$tmp" /etc/nginx/conf.d/cf_guard.conf
    echo "${green}$(msg cf_ips_ok)${reset}"
}

toggleCfGuard() {
    if [ -f /etc/nginx/conf.d/cf_guard.conf ]; then
        echo -e "${yellow}$(msg cfguard_disable_confirm) $(msg yes_no)${reset}"
        read -r confirm
        if [[ "$confirm" == "y" ]]; then
            rm -f /etc/nginx/conf.d/cf_guard.conf
            sed -i '/cloudflare_ip.*!=.*1/d' "$nginxPath" 2>/dev/null || true
            nginx -t && systemctl reload nginx
            echo "${green}$(msg cfguard_disabled)${reset}"
        fi
    else
        _fetchCfGuardIPs || return 1
        local wsPath
        wsPath=$(jq -r ".inbounds[0].streamSettings.wsSettings.path" "$configPath" 2>/dev/null)
        if [ -n "$wsPath" ] && [ "$wsPath" != "null" ]; then
            if ! grep -q "cloudflare_ip" "$nginxPath" 2>/dev/null; then
                sed -i "s/\(\s*location ${wsPath//\//\\/} {)/    if (\$cloudflare_ip != 1) { return 444; }\n\n\1/" "$nginxPath" 2>/dev/null || true
            fi
        fi
        nginx -t || { echo "${red}$(msg nginx_syntax_err)${reset}"; return 1; }
        systemctl reload nginx
        echo "${green}$(msg cfguard_enabled)${reset}"
    fi
}

openPort80() {
    ufw status | grep -q inactive && return
    ufw allow from any to any port 80 proto tcp comment 'ACME temp'
}

closePort80() {
    ufw status | grep -q inactive && return
    ufw status numbered | grep 'ACME temp' | awk -F"[][]" '{print $2}' | sort -rn | while read -r n; do
        echo "y" | ufw delete "$n"
    done
}

configCert() {
    if [[ -z "${userDomain:-}" ]]; then
        read -rp "$(msg ssl_enter_domain)" userDomain
    fi
    [ -z "$userDomain" ] && { echo "${red}$(msg ssl_domain_empty)${reset}"; return 1; }
    
    # ✅ Проверка существующего сертификата
    if [ -f /etc/nginx/cert/cert.pem ]; then
        local expire_date expire_epoch now_epoch days_left domain_in_cert
        
        # Срок действия
        expire_date=$(openssl x509 -enddate -noout -in /etc/nginx/cert/cert.pem 2>/dev/null | cut -d= -f2)
        expire_epoch=$(date -d "$expire_date" +%s 2>/dev/null)
        now_epoch=$(date +%s)
        days_left=$(( (expire_epoch - now_epoch) / 86400 ))
        
        # Домен в сертификате
        domain_in_cert=$(openssl x509 -noout -text -in /etc/nginx/cert/cert.pem 2>/dev/null | grep -oP '(?<=DNS:)[^,\s]+' | head -1)
        
        # Если сертификат валиден и для нужного домена
        if [ -n "$expire_epoch" ] && [ "$days_left" -gt 15 ] && [ "$domain_in_cert" = "$userDomain" ]; then
            echo -e "${green}✅ $(msg diag_ssl_ok)${reset}"
            echo -e "  Домен: ${cyan}$userDomain${reset}"
            echo -e "  Осталось дней действия: ${green}$days_left${reset}"
            echo ""
            read -rp "$(msg ssl_reissue_confirm) $(msg yes_no) " reissue
            [[ "$reissue" != "y" ]] && { echo "$(msg cancel)"; return 0; }
        fi
    fi
    
    echo -e "\n${cyan}$(msg ssl_method)${reset}"
    echo "$(msg ssl_method_1)"
    echo "$(msg ssl_method_2)"
    read -rp "$(msg ssl_your_choice)" cert_method
    installPackage "socat" || true
    if [ ! -f ~/.acme.sh/acme.sh ]; then
        curl -fsSL https://get.acme.sh | sh -s email="acme@${userDomain}"
    fi
    if [ ! -f ~/.acme.sh/acme.sh ]; then
        echo "${red}$(msg acme_install_fail)${reset}"; return 1
    fi
    ~/.acme.sh/acme.sh --upgrade --auto-upgrade
    ~/.acme.sh/acme.sh --set-default-ca --server letsencrypt
    if [ "$cert_method" == "1" ]; then
        [ -f "$cf_key_file" ] && source "$cf_key_file"
        if [[ -z "${CF_Email:-}" || -z "${CF_Key:-}" ]]; then
            read -rp "$(msg ssl_cf_email)" CF_Email
            read -rp "$(msg ssl_cf_key)" CF_Key
            printf "export CF_Email='%s'\nexport CF_Key='%s'\n" "$CF_Email" "$CF_Key" > "$cf_key_file"
            chmod 600 "$cf_key_file"
        fi
        # Передаем ключи только локально в окружение запуска процесса acme.sh, не оставляем в среде скрипта
        CF_Email="$CF_Email" CF_Key="$CF_Key" ~/.acme.sh/acme.sh --issue --dns dns_cf -d "$userDomain"
    else
        openPort80
        ~/.acme.sh/acme.sh --issue --standalone -d "$userDomain" \
            --pre-hook "/usr/local/bin/vwn open-80" \
            --post-hook "/usr/local/bin/vwn close-80"
        closePort80
    fi
    mkdir -p /etc/nginx/cert
    ~/.acme.sh/acme.sh --install-cert -d "$userDomain" \
        --key-file /etc/nginx/cert/cert.key \
        --fullchain-file /etc/nginx/cert/cert.pem \
        --reloadcmd "systemctl reload nginx"

    # Даём пользователю xray доступ к cert.key — нужно для xray-vision
    chmod 640 /etc/nginx/cert/cert.key
    chown root:xray /etc/nginx/cert/cert.key 2>/dev/null || true

    echo "${green}$(msg ssl_success) $userDomain${reset}"
}

applyNginxSub() {
    [ ! -f "$nginxPath" ] && return 1
    _writeSubMapConf
    if ! grep -q 'location ~ \^/sub/' "$nginxPath"; then
        sed -i '/location \/ {/i\    location ~ ^/sub/[A-Za-z0-9_-]+_[A-Za-z0-9]+\\.html$ {\n        root /usr/local/etc/xray;\n        try_files $uri =404;\n        types { text/html html; }\n        add_header Cache-Control '\''no-cache, no-store, must-revalidate'\'';\n    }\n\n    location ~ ^/sub/[A-Za-z0-9_-]+_[A-Za-z0-9]+\\.txt$ {\n        root /usr/local/etc/xray;\n        try_files $uri =404;\n        default_type text/plain;\n        add_header Content-Disposition "attachment; filename=\\"$sub_label.txt\\"";\n        add_header profile-title "$sub_label";\n        add_header Cache-Control '\''no-cache, no-store, must-revalidate'\'';\n    }\n' "$nginxPath" 2>/dev/null || true
    fi
    nginx -t && systemctl reload nginx
}
