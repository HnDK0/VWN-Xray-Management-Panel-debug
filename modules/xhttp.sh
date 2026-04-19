#!/bin/bash
# =================================================================
# xhttp.sh — VLESS + Vision + XHTTP Transport (CDN совместимый)
#
# Архитектура:
#   ✅ Работает параллельно с Vision на одном порту 443
#   ✅ Xray XHTTP инбаунд слушает локально на 127.0.0.1:45000
#   ✅ Nginx пробрасывает трафик с пути /xhttp на этот инбаунд
#   ✅ Полностью совместим со всеми CDN включая Cloudflare
#   ✅ Никаких конфликтов с существующей конфигурацией
# =================================================================

XHTTP_SERVICE="/etc/systemd/system/xray-xhttp.service"
xhttpConfigPath="/usr/local/etc/xray/xhttp.json"

_ensureXhttpLogAccess() {
    mkdir -p /var/log/xray
    touch /var/log/xray/xhttp-error.log || true
    chown -R xray:xray /var/log/xray || true
    chmod 750 /var/log/xray || true
    chmod 640 /var/log/xray/xhttp-error.log || true
}

# ── Статус ────────────────────────────────────────────────────────

getXhttpStatus() {
    if [ ! -f "$xhttpConfigPath" ]; then
        echo "${red}NOT INSTALLED${reset}"
        return
    fi
    if systemctl is-active --quiet xray-xhttp; then
        local domain
        domain=$(vwn_conf_get DOMAIN || true)
        echo "${green}RUNNING${reset} | ${domain:-?}:443/xhttp (CDN mode)"
    else
        echo "${red}STOPPED${reset}"
    fi
}

# ── Генерация конфига Xray ─────────────────────────────────────────

writeXhttpConfig() {
    local uuid="$1"
    local path="$2"
    local domain="$3"

    mkdir -p "$(dirname "$xhttpConfigPath")"
    _ensureXhttpLogAccess

    render_config "$VWN_CONFIG_DIR/xray_xhttp.json" "$xhttpConfigPath" \
        UUID "$uuid" \
        PATH "$path" \
        DOMAIN "$domain"

    chown xray:xray "$xhttpConfigPath" || true
    chmod 640 "$xhttpConfigPath" || true
    echo "${green}XHTTP config written: $xhttpConfigPath${reset}"
}

# ── Systemd сервис ────────────────────────────────────────────────

setupXhttpService() {
    cat > "$XHTTP_SERVICE" << 'EOF'
[Unit]
Description=Xray XHTTP Service
After=network.target nss-lookup.target

[Service]
User=xray
CapabilityBoundingSet=CAP_NET_ADMIN CAP_NET_BIND_SERVICE
AmbientCapabilities=CAP_NET_ADMIN CAP_NET_BIND_SERVICE
NoNewPrivileges=true
ExecStart=/usr/local/bin/xray run -config /usr/local/etc/xray/xhttp.json
Restart=on-failure
RestartSec=10
LimitNOFILE=infinity

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable xray-xhttp
    systemctl restart xray-xhttp
    sleep 2

    if systemctl is-active --quiet xray-xhttp; then
        echo "${green}xray-xhttp service started.${reset}"
    else
        echo "${red}xray-xhttp failed to start. Check: journalctl -u xray-xhttp -n 30${reset}"
        return 1
    fi
}

# ── Применение активных фич ───────────────────────────────────────

_xhttpApplyActiveFeatures() {
    echo -e "${cyan}Applying active features to XHTTP config${reset}"

    # WARP
    if command -v warp-cli; then
        local warp_raw warp_rule
        warp_raw=$(getWarpStatusRaw || echo "OFF")
        if [ "$warp_raw" = "ACTIVE" ] && [ -f "$configPath" ]; then
            warp_rule=$(jq -r '.routing.rules[] | select(.outboundTag=="warp") | if .port == "0-65535" then "Global" elif (.domain | length) > 0 then "Split" else "" end' "$configPath" | head -1)
            case "$warp_rule" in
                Global)
                    jq '(.routing.rules[] | select(.outboundTag == "warp")) |= (.port = "0-65535" | del(.domain))' \
                        "$xhttpConfigPath" > "${xhttpConfigPath}.tmp" && mv "${xhttpConfigPath}.tmp" "$xhttpConfigPath" || true
                    ;;
                Split) applyWarpDomains || true ;;
            esac
        fi
    fi

    # Adblock
    if _adblockIsEnabled; then
        _adblockApplyToConfig "$xhttpConfigPath" || true
    fi

    # Privacy mode
    if _privacyIsEnabled; then
        _xrayDisableLog "$xhttpConfigPath" || true
    fi
}

# ── Основная установка ────────────────────────────────────────────

installXhttp() {
    local auto_mode=false
    [ "${1:-}" = "--auto" ] && auto_mode=true

    clear
    echo -e "${cyan}================================================================${reset}"
    echo -e "   Vision + XHTTP Transport (CDN Compatible)"
    echo -e "${cyan}================================================================${reset}"
    echo ""

    # Проверяем что есть работающий Vision
    if [ ! -f "$visionConfigPath" ]; then
        echo "${red}Сначала установите Vision. XHTTP работает поверх существующей Vision установки.${reset}"
        return 1
    fi

    # Домен и UUID из существующего Vision
    local xhttp_domain xhttp_uuid xhttp_path
    xhttp_domain=$(vwn_conf_get DOMAIN || true)
    xhttp_uuid=$(vwn_conf_get VISION_UUID || true)
    
    # Генерируем уникальный путь как у WebSocket
    xhttp_path="/api/v2/$(cat /dev/urandom | tr -dc 'a-zA-Z0-9' | fold -w 12 | head -n 1)"

    echo -e "${cyan}Используется домен:${reset} ${green}${xhttp_domain}${reset}"
    echo -e "${cyan}Путь:${reset} ${green}${xhttp_path}${reset}"
    echo ""

    # Конфиг Xray
    echo -e "${cyan}Установка XHTTP конфигурации...${reset}"
    writeXhttpConfig "$xhttp_uuid" "$xhttp_path" "$xhttp_domain"

    # Обновляем Nginx конфиг — добавляем location для XHTTP
    local proxy_url
    proxy_url=$(vwn_conf_get STUB_URL || echo "https://www.bing.com/")
    writeNginxConfigVision "$proxy_url" "$xhttp_domain"

    # Сервис
    setupXhttpService || return 1

    # Применяем активные фичи
    _xhttpApplyActiveFeatures

    # Сохраняем мета-данные
    vwn_conf_set XHTTP_ENABLED "true"
    vwn_conf_set XHTTP_PATH "$xhttp_path"

    # Итог
    echo ""
    echo -e "${green}================================================================${reset}"
    echo -e "   Vision XHTTP успешно установлен"
    echo -e "${green}================================================================${reset}"
    showXhttpInfo

    # Перегенерируем подписки
    rebuildAllSubFiles || true
}

# ── Информация ────────────────────────────────────────────────────

showXhttpInfo() {
    if [ ! -f "$xhttpConfigPath" ]; then
        echo "${red}XHTTP не установлен${reset}"
        return
    fi

    local domain uuid server_ip path
    domain=$(vwn_conf_get DOMAIN || true)
    uuid=$(vwn_conf_get VISION_UUID || true)
    server_ip=$(getServerIP)
    path=$(vwn_conf_get XHTTP_PATH || echo "/xhttp")

    echo ""
    echo -e "${cyan}━━━ Vision XHTTP (CDN) ━━━${reset}"
    echo ""
    echo -e "  ${cyan}Домен:${reset}  ${green}${domain:-?}${reset}"
    echo -e "  ${cyan}UUID:${reset}    ${green}${uuid:-?}${reset}"
    echo -e "  ${cyan}Порт:${reset}    ${green}443${reset}"
    echo -e "  ${cyan}Путь:${reset}    ${green}${path}${reset}"
    echo -e "  ${cyan}Тип:${reset}     VLESS + XHTTP"
    echo -e "  ${cyan}Тип:${reset}     xhttp"
    echo -e "  ${cyan}Статус:${reset}  $(getXhttpStatus)"
    echo ""
    echo -e " ✅ Полностью совместимо со всеми CDN"
    echo -e " ✅ Работает параллельно с обычным Vision"
    echo ""
}

showXhttpQR() {
    if [ ! -f "$xhttpConfigPath" ]; then
        echo "${red}XHTTP не установлен${reset}"
        return
    fi

    local domain uuid path
    domain=$(vwn_conf_get DOMAIN || true)
    uuid=$(vwn_conf_get VISION_UUID || true)
    path=$(vwn_conf_get XHTTP_PATH || echo "/xhttp")

    [ -z "$domain" ] || [ -z "$uuid" ] && {
        echo "${red}XHTTP не установлен${reset}"; return
    }

    local flag server_ip v_label v_name v_encoded_name modes
    server_ip=$(getServerIP || echo "")
    flag=$(_getCountryFlag "$server_ip" || echo "🌐")
    modes=$(_getActiveModesSuffix || true)
    v_label="default"
    [ -f "$USERS_FILE" ] && v_label=$(cut -d'|' -f2 "$USERS_FILE" | head -1)
    v_name="${flag} VL-XHTTP | ${v_label} ${flag}${modes}"
    v_encoded_name=$(python3 -c "import sys,urllib.parse; print(urllib.parse.quote(sys.argv[1]))" "$v_name" || echo "$v_name")

    local link
    link="vless://${uuid}@${domain}:443?security=tls&type=xhttp&path=${path}&sni=${domain}&fp=chrome&allowInsecure=0#${v_encoded_name}"

    echo -e "${cyan}Vision XHTTP ссылка:${reset}"
    echo ""
    if command -v qrencode; then
        qrencode -t ANSIUTF8 "$link"
    fi
    echo ""
    echo -e "${green}${link}${reset}"
    echo ""
}

# ── Удаление ──────────────────────────────────────────────────────

removeXhttp() {
    echo -e "${red}Удалить XHTTP? $(msg yes_no)${reset}"
    read -r confirm
    [[ "$confirm" != "y" ]] && { echo "$(msg cancel)"; return; }

    echo -e "${cyan}Удаление XHTTP...${reset}"

    systemctl stop xray-xhttp || true
    systemctl disable xray-xhttp || true
    rm -f "$XHTTP_SERVICE"
    systemctl daemon-reload

    rm -f "$xhttpConfigPath"

    vwn_conf_del XHTTP_ENABLED
    vwn_conf_del XHTTP_PATH

    # Пересобираем Nginx конфиг без XHTTP
    local proxy_url domain
    proxy_url=$(vwn_conf_get STUB_URL || echo "https://www.bing.com/")
    domain=$(vwn_conf_get DOMAIN || true)
    writeNginxConfigVision "$proxy_url" "$domain"

    nginx -t && systemctl reload nginx || true

    # Перегенерируем подписки
    rebuildAllSubFiles || true

    echo "${green}XHTTP удалён${reset}"
}

# ── Пересоздание конфигов ─────────────────────────────────────────

rebuildXhttpConfigs() {
    if [ ! -f "$xhttpConfigPath" ]; then
        echo "${red}XHTTP не установлен${reset}"; return 1
    fi

    local xhttp_uuid xhttp_path xhttp_domain
    xhttp_uuid=$(vwn_conf_get VISION_UUID || true)
    xhttp_path=$(vwn_conf_get XHTTP_PATH || echo "/xhttp")
    xhttp_domain=$(vwn_conf_get DOMAIN || true)

    echo -e "${cyan}Rebuilding XHTTP configs...${reset}"

    writeXhttpConfig "$xhttp_uuid" "$xhttp_path" "$xhttp_domain"
    _xhttpApplyActiveFeatures

    systemctl restart xray-xhttp || true

    echo "${green}XHTTP конфиги пересозданы${reset}"
}

# ── Меню ──────────────────────────────────────────────────────────

manageXhttp() {
    set +e
    while true; do
        clear
        echo -e "${cyan}================================================================${reset}"
        printf "   ${red}Vision XHTTP (CDN)${reset}  %s\n" "$(date +'%d.%m.%Y %H:%M')"
        echo -e "${cyan}----------------------------------------------------------------${reset}"
        echo -e "  Статус: $(getXhttpStatus)"
        if [ -f "$xhttpConfigPath" ]; then
            local _dom _path
            _dom=$(vwn_conf_get DOMAIN || true)
            _path=$(vwn_conf_get XHTTP_PATH || echo "/xhttp")
            echo -e "  Домен: ${green}${_dom:-?}${reset}"
            echo -e "  Путь:  ${green}${_path}${reset}"
        fi
        echo -e "${cyan}----------------------------------------------------------------${reset}"
        echo ""
        echo -e "${green}1.${reset} Установить XHTTP"
        echo -e "${green}2.${reset} Показать информацию"
        echo -e "${green}3.${reset} Показать QR код"
        echo -e "${green}4.${reset} Пересоздать конфиги"
        echo -e "${green}5.${reset} Удалить XHTTP"
        echo -e "${green}0.${reset} $(msg back)"
        echo ""
        read -rp "$(msg choose)" choice
        case $choice in
            1) installXhttp ;;
            2) showXhttpInfo ;;
            3) showXhttpQR ;;
            4) rebuildXhttpConfigs ;;
            5) removeXhttp ;;
            0) break ;;
        esac
        [ "$choice" = "0" ] && continue
        echo -e "\n${cyan}$(msg press_enter)${reset}"
        read -r
    done
}