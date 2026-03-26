# VWN — Xray Management Panel v4.0

Установщик и панель управления для Xray (VLESS + WebSocket + TLS / Reality) на слабых VPS.

## Возможности

- **VLESS + WebSocket + TLS** — через Nginx с Cloudflare CDN
- **VLESS + Reality** — без домена и сертификата
- **Cloudflare WARP** — Global / Split / OFF режимы
- **Psiphon** — обход DPI с выбором страны
- **Tor** — с мостами (obfs4, snowflake, meek-azure)
- **Relay** — подключение к внешним серверам
- **Мульти-юзер** — каждый пользователь получает свою подписку
- **Веб-панель** — управление через браузер (127.0.0.1:8444)
- **Подписки** — URL + HTML страница с QR-кодами и Clash конфигами

## Установка

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/HnDK0/VWN-Xray-Management-Panel/main/install.sh)
```

## Обновление

```bash
vwn update
```

или

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/HnDK0/VWN-Xray-Management-Panel/main/install.sh) --update
```

## Использование

```bash
vwn
```

## Требования

- Linux (Ubuntu/Debian/CentOS)
- Root доступ
- 512 MB RAM (рекомендуется)
- Домен с DNS записью (для WS+TLS)

## Архитектура

```
/usr/local/lib/vwn/          — модули
/usr/local/bin/vwn            — загрузчик
/usr/local/etc/xray/          — конфиги
/etc/nginx/conf.d/xray.conf   — nginx конфиг
```

## Модули

| Модуль | Описание |
|--------|----------|
| core.sh | Общие переменные и утилиты |
| xray.sh | Управление Xray конфигами |
| nginx.sh | Nginx конфигурация и SSL |
| reality.sh | VLESS + Reality |
| warp.sh | Cloudflare WARP |
| psiphon.sh | Psiphon туннели |
| tor.sh | Tor с мостами |
| relay.sh | Внешние серверы |
| users.sh | Управление пользователями |
| security.sh | UFW, Fail2Ban, BBR |
| logs.sh | Логи и ротация |
| backup.sh | Бэкапы |
| panel.sh | Веб-панель |
| web_panel.py | Backend веб-панели |
| lang.sh | Локализация (RU/EN) |
| menu.sh | Главное меню |
| diag.sh | Диагностика |
| update.sh | Обновление модулей |

## Безопасность

- JWT аутентификация с HMAC-SHA256
- bcrypt хэширование паролей (12 раундов)
- Rate limiting (5 попыток за 15 минут)
- CSRF защита
- Content Security Policy с nonce
- Whitelist команд
- Audit logging
- Systemd с NoNewPrivileges
- Fail2Ban для SSH и Nginx
- CF Guard (опционально)

## Лицензия

MIT