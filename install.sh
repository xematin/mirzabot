#!/bin/bash
# ╔══════════════════════════════════════════════════════════════╗
# ║          MirzaBot Docker Manager — install.sh               ║
# ║  Multi-bot runner using Docker + Nginx reverse proxy        ║
# ║  Repo: https://github.com/xematin/mirzabot                 ║
# ╚══════════════════════════════════════════════════════════════╝
# Usage:  bash install.sh
# Shortcut after first run:  mirza

set -euo pipefail

# ── Root check ─────────────────────────────────────────────────
if [[ $EUID -ne 0 ]]; then
    echo "[ERROR] Please run as root."
    exit 1
fi

# ── Colors ─────────────────────────────────────────────────────
R='\033[31m'; G='\033[32m'; Y='\033[33m'
B='\033[34m'; C='\033[36m'; W='\033[0m'; BOLD='\033[1m'

info()    { echo -e "${C}[•]${W} $*"; }
success() { echo -e "${G}[✓]${W} $*"; }
warn()    { echo -e "${Y}[!]${W} $*"; }
err()     { echo -e "${R}[✗]${W} $*"; exit 1; }
ask()     { echo -e "${Y}[?]${W} $*"; }

# ── Paths & constants ───────────────────────────────────────────
BASE_DIR="/opt/mirzabots"
MASTER_CONF="$BASE_DIR/.mirza.conf"
COMPOSE_FILE="$BASE_DIR/docker-compose.yml"
MYSQL_INIT_DIR="$BASE_DIR/mysql-init"
MASTER_PATH="/root/mirza-docker.sh"
BIN_LINK="/usr/local/bin/mirza"

# ── URLs (فورک شما) ─────────────────────────────────────────────
GITHUB_REPO="xematin/mirzabot"
BOT_FILES_URL="https://github.com/${GITHUB_REPO}/archive/refs/heads/main.zip"
SELF_UPDATE_URL="https://raw.githubusercontent.com/${GITHUB_REPO}/main/install.sh"

# ══════════════════════════════════════════════════════════════
# SELF UPDATE
# ══════════════════════════════════════════════════════════════

self_update() {
    local tmp="/tmp/mirza_self_update_$$.sh"
    info "Checking for script updates from GitHub..."

    if wget -q -O "$tmp" "$SELF_UPDATE_URL" 2>/dev/null && [ -s "$tmp" ]; then
        local local_hash remote_hash
        local_hash=$(md5sum "$MASTER_PATH" 2>/dev/null | awk '{print $1}' || echo "none")
        remote_hash=$(md5sum "$tmp" | awk '{print $1}')

        if [ "$local_hash" != "$remote_hash" ]; then
            success "New version found! Updating script..."
            mv "$tmp" "$MASTER_PATH"
            chmod +x "$MASTER_PATH"
            ln -sf "$MASTER_PATH" "$BIN_LINK"
            info "Restarting with new version..."
            sleep 1
            exec bash "$MASTER_PATH" "$@"
        else
            success "Script is up to date."
            rm -f "$tmp"
        fi
    else
        warn "Could not check for updates (connection issue). Continuing with current version."
        rm -f "$tmp" 2>/dev/null || true
    fi
}

# ══════════════════════════════════════════════════════════════
# CONFIG MANAGEMENT
# ══════════════════════════════════════════════════════════════

load_master_conf() {
    mkdir -p "$BASE_DIR" "$MYSQL_INIT_DIR"
    if [ ! -f "$MASTER_CONF" ]; then
        MYSQL_ROOT_PASS=$(openssl rand -base64 20 | tr -dc 'a-zA-Z0-9' | cut -c1-18)
        BOTS=""
        {
            echo "MYSQL_ROOT_PASS=$MYSQL_ROOT_PASS"
            echo "BOTS="
        } > "$MASTER_CONF"
        chmod 600 "$MASTER_CONF"
        # Init empty SQL file
        echo "-- MirzaBot DB init" > "$MYSQL_INIT_DIR/init.sql"
    fi
    source "$MASTER_CONF"
}

save_master_conf() {
    {
        echo "MYSQL_ROOT_PASS=$MYSQL_ROOT_PASS"
        echo "BOTS=$BOTS"
    } > "$MASTER_CONF"
    chmod 600 "$MASTER_CONF"
}

# Per-bot conf lives at: $BASE_DIR/$name/.conf
load_bot_conf() {
    local name="$1"
    local conf="$BASE_DIR/$name/.conf"
    [ -f "$conf" ] || err "Bot config not found: $conf"
    source "$conf"
}

save_bot_conf() {
    local name="$1"
    local conf="$BASE_DIR/$name/.conf"
    {
        echo "SUBDOMAIN=$SUBDOMAIN"
        echo "PORT=$PORT"
        echo "DB_NAME=$DB_NAME"
        echo "DB_USER=$DB_USER"
        echo "DB_PASS=$DB_PASS"
        echo "TOKEN=$TOKEN"
        echo "CHAT_ID=$CHAT_ID"
        echo "BOT_USERNAME=$BOT_USERNAME"
        echo "BRAND_NAME=${BRAND_NAME:-میرزا}"
    } > "$conf"
    chmod 600 "$conf"
}

list_bots_array() {
    # Returns array of bot names from BOTS (comma-separated)
    IFS=',' read -ra BOT_LIST <<< "${BOTS:-}"
}

bot_count() {
    if [ -z "${BOTS:-}" ]; then echo 0; return; fi
    IFS=',' read -ra arr <<< "$BOTS"
    echo "${#arr[@]}"
}

add_bot_to_list() {
    local name="$1"
    # نام تکراری اضافه نمیکنیم
    if echo "${BOTS:-}" | tr ',' '\n' | grep -qx "$name"; then
        return 0
    fi
    if [ -z "${BOTS:-}" ]; then
        BOTS="$name"
    else
        BOTS="$BOTS,$name"
    fi
}

remove_bot_from_list() {
    local name="$1"
    BOTS=$(echo "$BOTS" | tr ',' '\n' | grep -v "^$name$" | tr '\n' ',' | sed 's/,$//')
}

next_bot_name() {
    local i=1
    while true; do
        local candidate="bot$i"
        local dir_exists=false
        local in_bots=false
        [ -d "$BASE_DIR/$candidate" ] && dir_exists=true
        echo "${BOTS:-}" | tr ',' '\n' | grep -qx "$candidate" && in_bots=true
        # نام آزاد = نه در دایرکتوری، نه در BOTS list
        if [ "$dir_exists" = "false" ] && [ "$in_bots" = "false" ]; then
            echo "$candidate"
            return
        fi
        ((i++))
    done
}

next_free_port() {
    local port=8081
    # Check ports in use by system
    while ss -tuln 2>/dev/null | grep -q ":$port "; do
        ((port++))
    done
    # Also check ports already assigned to bots
    list_bots_array
    for b in "${BOT_LIST[@]}"; do
        [ -z "$b" ] && continue
        local bconf="$BASE_DIR/$b/.conf"
        [ -f "$bconf" ] || continue
        local bport
        bport=$(grep '^PORT=' "$bconf" | cut -d= -f2)
        [ "$bport" = "$port" ] && ((port++))
    done
    echo $port
}

# ══════════════════════════════════════════════════════════════
# INFRASTRUCTURE
# ══════════════════════════════════════════════════════════════

install_prerequisites() {
    info "Checking prerequisites..."

    # Docker
    if ! command -v docker &>/dev/null; then
        info "Installing Docker..."
        curl -fsSL https://get.docker.com | bash -s -- -q
        systemctl enable docker --now
        success "Docker installed: $(docker --version)"
    else
        success "Docker: $(docker --version)"
    fi

    # Nginx
    if ! command -v nginx &>/dev/null; then
        info "Installing Nginx..."
        apt-get update -qq
        apt-get install -y -q nginx
        systemctl enable nginx --now
        success "Nginx installed."
    else
        success "Nginx: $(nginx -v 2>&1)"
    fi

    # Certbot
    if ! command -v certbot &>/dev/null; then
        info "Installing Certbot..."
        apt-get install -y -q certbot python3-certbot-nginx
        success "Certbot installed."
    else
        success "Certbot: $(certbot --version 2>&1)"
    fi

    # Misc tools
    apt-get install -y -q curl wget unzip openssl rsync 2>/dev/null || true

    # Remove default nginx site (if exists)
    rm -f /etc/nginx/sites-enabled/default 2>/dev/null || true
    nginx -t &>/dev/null && systemctl reload nginx 2>/dev/null || true
}

# ── Generate full docker-compose.yml from current state ────────
generate_compose() {
    list_bots_array

    cat > "$COMPOSE_FILE" << HEADER
version: '3.8'

services:

  # ── Shared MySQL ────────────────────────────────────────────
  mysql:
    image: mysql:8.0
    container_name: mirza_mysql
    restart: always
    environment:
      MYSQL_ROOT_PASSWORD: "${MYSQL_ROOT_PASS}"
    volumes:
      - mysql_data:/var/lib/mysql
      - ./mysql-init:/docker-entrypoint-initdb.d
    networks:
      - mirza_net
    healthcheck:
      test: ["CMD", "mysqladmin", "ping", "-h", "localhost", "-uroot", "-p${MYSQL_ROOT_PASS}"]
      interval: 10s
      timeout: 5s
      retries: 10
      start_period: 30s

HEADER

    for b in "${BOT_LIST[@]}"; do
        [ -z "$b" ] && continue
        local bconf="$BASE_DIR/$b/.conf"
        [ -f "$bconf" ] || continue
        local bport
        bport=$(grep '^PORT=' "$bconf" | cut -d= -f2)

        cat >> "$COMPOSE_FILE" << BOT_ENTRY
  # ── $b ──────────────────────────────────────────────────────
  $b:
    build:
      context: ./$b
    container_name: mirza_$b
    restart: always
    ports:
      - "$bport:80"
    depends_on:
      mysql:
        condition: service_healthy
    networks:
      - mirza_net

BOT_ENTRY
    done

    cat >> "$COMPOSE_FILE" << FOOTER
volumes:
  mysql_data:

networks:
  mirza_net:
    driver: bridge
FOOTER
}

# ── Dockerfile for each bot container ──────────────────────────
create_dockerfile() {
    local bot_dir="$1"
    cat > "$bot_dir/Dockerfile" << 'DOCKERFILE'
FROM php:8.2-apache

RUN apt-get update && apt-get install -y \
        libzip-dev \
        libpng-dev \
        libonig-dev \
        libssh2-1-dev \
        libssh2-1 \
        libcurl4-openssl-dev \
        libxml2-dev \
        libfreetype6-dev \
        libjpeg62-turbo-dev \
        curl unzip wget \
    && docker-php-ext-configure gd \
        --with-freetype \
        --with-jpeg \
    && docker-php-ext-install \
        mysqli \
        pdo \
        pdo_mysql \
        mbstring \
        zip \
        gd \
        curl \
        soap \
    && a2enmod rewrite \
    && rm -rf /var/lib/apt/lists/*

COPY ./files/ /var/www/html/
COPY ./config.php /var/www/html/config.php

RUN chown -R www-data:www-data /var/www/html \
    && chmod -R 755 /var/www/html

EXPOSE 80
DOCKERFILE
}

# ── جایگزینی نام برند در فایل‌های ربات ───────────────────────────
replace_brand_name() {
    local files_dir="$1"
    local brand="$2"

    info "Replacing brand name with: $brand ..."

    # panel/inc/layout_head.php
    local layout="$files_dir/panel/inc/layout_head.php"
    if [ -f "$layout" ]; then
        sed -i "s|پنل مدیریت میرزا بات|پنل مدیریت $brand|g" "$layout"
        sed -i "s|میرزا<span> · پنل</span>|$brand<span> · پنل</span>|g" "$layout"
        sed -i "s|<span>میرزا</span>|<span>$brand</span>|g" "$layout"
    fi

    # panel/login.php
    local login="$files_dir/panel/login.php"
    if [ -f "$login" ]; then
        sed -i "s|پنل مدیریت میرزا|پنل مدیریت $brand|g" "$login"
        sed -i "s|نسخه 1.0 میرزا|$brand|g" "$login"
    fi

    # admin.php — پیام خوش‌آمدگویی
    local admin="$files_dir/admin.php"
    if [ -f "$admin" ]; then
        sed -i "s|تیم میرزا|تیم $brand|g" "$admin"
    fi

    success "Brand name replaced: میرزا → $brand"
}

# ── Download bot PHP files from GitHub (xematin/mirzabot) ─────
download_bot_files() {
    local target="$1/files"
    info "Downloading MirzaBot source from github.com/${GITHUB_REPO} ..."
    mkdir -p "$target"
    local tmp="/tmp/mirza_dl_$$"
    mkdir -p "$tmp"

    wget -q --show-progress -O "$tmp/bot.zip" "$BOT_FILES_URL" \
        || err "Download failed. Check internet or repo URL."

    unzip -q "$tmp/bot.zip" -d "$tmp"

    # Repo extracts as mirzabot-main/ — files are directly inside root
    local extracted
    extracted=$(find "$tmp" -mindepth 1 -maxdepth 1 -type d | head -1)

    # Copy all files EXCEPT config.php (we generate our own)
    rsync -a --exclude='config.php' --exclude='install.sh' "$extracted/" "$target/"

    rm -rf "$tmp"
    success "Bot files downloaded ($(ls "$target" | wc -l) items)."
}

# ── config.php — matches xematin/mirzabot format exactly ───────
create_config_php() {
    local bot_dir="$1"
    # Vars in scope: DB_NAME DB_USER DB_PASS TOKEN CHAT_ID SUBDOMAIN BOT_USERNAME
    # Note: $dbhost = 'mysql'  →  Docker service name (resolves inside mirza_net)
    cat > "$bot_dir/config.php" << PHP
<?php
// This variable added for high load panels which their response time is long
// null for default settings
\$request_exec_timeout = null;
\$dbhost     = 'mysql';
\$dbname     = '$DB_NAME';
\$usernamedb = '$DB_USER';
\$passworddb = '$DB_PASS';
\$connect = mysqli_connect(\$dbhost, \$usernamedb, \$passworddb, \$dbname);
if (\$connect->connect_error) { die("error" . \$connect->connect_error); }
mysqli_set_charset(\$connect, "utf8mb4");
\$options = [ PDO::ATTR_ERRMODE => PDO::ERRMODE_EXCEPTION, PDO::ATTR_DEFAULT_FETCH_MODE => PDO::FETCH_ASSOC, PDO::ATTR_EMULATE_PREPARES => false, ];
\$dsn = "mysql:host=\$dbhost;dbname=\$dbname;charset=utf8mb4";
try { \$pdo = new PDO(\$dsn, \$usernamedb, \$passworddb, \$options); } catch (\PDOException \$e) { error_log("Database connection failed: " . \$e->getMessage()); }
\$APIKEY      = '$TOKEN';
\$adminnumber = '$CHAT_ID';
\$domainhosts = '$SUBDOMAIN';
\$usernamebot = '$BOT_USERNAME';
?>
PHP
}

# ── Nginx reverse proxy config per subdomain ───────────────────
create_nginx_conf() {
    local subdomain="$1"
    local port="$2"
    local conf_path="/etc/nginx/sites-available/${subdomain}.conf"

    cat > "$conf_path" << NGINX
server {
    listen 80;
    server_name $subdomain;
    return 301 https://\$host\$request_uri;
}

server {
    listen 443 ssl;
    server_name $subdomain;

    ssl_certificate     /etc/letsencrypt/live/$subdomain/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/$subdomain/privkey.pem;
    ssl_protocols       TLSv1.2 TLSv1.3;
    ssl_ciphers         HIGH:!aNULL:!MD5;

    client_max_body_size 64M;

    location / {
        proxy_pass         http://127.0.0.1:$port;
        proxy_set_header   Host              \$host;
        proxy_set_header   X-Real-IP         \$remote_addr;
        proxy_set_header   X-Forwarded-For   \$proxy_add_x_forwarded_for;
        proxy_set_header   X-Forwarded-Proto https;
        proxy_set_header   X-Original-IP     \$remote_addr;
        proxy_read_timeout 60s;
    }
}
NGINX

    ln -sf "$conf_path" "/etc/nginx/sites-enabled/${subdomain}.conf"
    nginx -t &>/dev/null && systemctl reload nginx \
        || warn "Nginx config test failed — check manually."
}

remove_nginx_conf() {
    local subdomain="$1"
    rm -f "/etc/nginx/sites-enabled/${subdomain}.conf"
    rm -f "/etc/nginx/sites-available/${subdomain}.conf"
    nginx -t &>/dev/null && systemctl reload nginx 2>/dev/null || true
}

# ── Get SSL cert (standalone, stops nginx briefly) ─────────────
get_ssl() {
    local subdomain="$1"
    info "Getting SSL certificate for $subdomain ..."

    # Check DNS first
    local server_ip
    server_ip=$(curl -4 -s --connect-timeout 5 ifconfig.me || echo "")
    local dns_ip
    dns_ip=$(getent hosts "$subdomain" 2>/dev/null | awk '{print $1}' | head -1 || echo "")

    if [ -n "$server_ip" ] && [ "$dns_ip" != "$server_ip" ]; then
        warn "DNS mismatch: $subdomain → '$dns_ip'  (server IP: $server_ip)"
        warn "Make sure your DNS A record points to this server before continuing."
        read -rp "$(echo -e ${Y}Continue anyway? [y/N]:${W} )" dns_ok
        [[ "$dns_ok" =~ ^[Yy]$ ]] || err "Aborted. Fix DNS first."
    fi

    systemctl stop nginx 2>/dev/null || true

    certbot certonly \
        --standalone \
        --agree-tos \
        --non-interactive \
        --preferred-challenges http \
        --register-unsafely-without-email \
        -d "$subdomain" \
        || { systemctl start nginx; err "SSL failed. Check DNS and port 80."; }

    systemctl start nginx
    success "SSL certificate issued for $subdomain."
}

# ── Create DB directly in running MySQL container ──────────────
create_db_live() {
    docker exec mirza_mysql mysql -uroot -p"$MYSQL_ROOT_PASS" -e "
        CREATE DATABASE IF NOT EXISTS \`$DB_NAME\` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
        CREATE USER IF NOT EXISTS '$DB_USER'@'%' IDENTIFIED BY '$DB_PASS';
        GRANT ALL PRIVILEGES ON \`$DB_NAME\`.* TO '$DB_USER'@'%';
        FLUSH PRIVILEGES;
    " 2>/dev/null && success "Database $DB_NAME created." \
        || warn "Live DB create had issues — will use init.sql on next MySQL start."
}

# ── Append DB creation to init.sql (for fresh MySQL starts) ───
append_db_init_sql() {
    cat >> "$MYSQL_INIT_DIR/init.sql" << SQL
CREATE DATABASE IF NOT EXISTS \`$DB_NAME\` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
CREATE USER IF NOT EXISTS '$DB_USER'@'%' IDENTIFIED BY '$DB_PASS';
GRANT ALL PRIVILEGES ON \`$DB_NAME\`.* TO '$DB_USER'@'%';
FLUSH PRIVILEGES;
SQL
}

# ── Wait for a container to be healthy ─────────────────────────
wait_healthy() {
    local container="$1"
    local retries=30
    info "Waiting for $container to be ready..."
    while [ $retries -gt 0 ]; do
        local health
        health=$(docker inspect --format='{{.State.Health.Status}}' "$container" 2>/dev/null || echo "none")
        [ "$health" = "healthy" ] && { success "$container is ready."; return 0; }
        sleep 3
        ((retries--))
    done
    warn "$container did not become healthy in time. Continuing anyway."
}

# ══════════════════════════════════════════════════════════════
# MENU ACTIONS
# ══════════════════════════════════════════════════════════════

# ── 1. Install a new bot ───────────────────────────────────────
action_install() {
    clear
    echo -e "${BOLD}${C}══════════════════════════════════════${W}"
    echo -e "${BOLD}${C}      Install New MirzaBot 🤖         ${W}"
    echo -e "${BOLD}${C}══════════════════════════════════════${W}"
    echo ""

    # ── Collect inputs ────────────────────────────────────────
    ask "Subdomain (e.g. bot1.botgram.my.id):"
    read -rp "  > " SUBDOMAIN
    while [[ ! "$SUBDOMAIN" =~ ^[a-zA-Z0-9]([a-zA-Z0-9\-]{0,61}[a-zA-Z0-9])?(\.[a-zA-Z0-9]([a-zA-Z0-9\-]{0,61}[a-zA-Z0-9])?)+$ ]]; do
        echo -e "${R}  Invalid domain format.${W}"
        read -rp "  > " SUBDOMAIN
    done

    ask "Bot Token (from @BotFather):"
    read -rp "  > " TOKEN
    while [[ ! "$TOKEN" =~ ^[0-9]{8,12}:[a-zA-Z0-9_-]{35}$ ]]; do
        echo -e "${R}  Invalid token format.${W}"
        read -rp "  > " TOKEN
    done

    ask "Admin Chat ID (use @userinfobot to find it):"
    read -rp "  > " CHAT_ID
    while [[ ! "$CHAT_ID" =~ ^-?[0-9]+$ ]]; do
        echo -e "${R}  Invalid chat ID (numbers only).${W}"
        read -rp "  > " CHAT_ID
    done

    ask "Bot username (without @):"
    read -rp "  > " BOT_USERNAME
    while [ -z "$BOT_USERNAME" ]; do
        echo -e "${R}  Cannot be empty.${W}"
        read -rp "  > " BOT_USERNAME
    done

    ask "Brand name (نام برند/پنل شما — جایگزین 'میرزا' میشه، مثلاً: VpnShop):"
    read -rp "  > " BRAND_NAME
    while [ -z "$BRAND_NAME" ]; do
        echo -e "${R}  Cannot be empty.${W}"
        read -rp "  > " BRAND_NAME
    done

    # ── پاکسازی ربات ناموفق قبلی (اگه وجود داره) ──────────────
    list_bots_array
    for b in "${BOT_LIST[@]:-}"; do
        [ -z "$b" ] && continue
        local bconf="$BASE_DIR/$b/.conf"
        [ -f "$bconf" ] || { remove_bot_from_list "$b"; save_master_conf; continue; }
        local existing_sub
        existing_sub=$(grep "^SUBDOMAIN=" "$bconf" | cut -d= -f2)
        # اگه subdomain یکیه یا container خراب و فایل‌ها ناقصن
        local is_broken=false
        if [ "$existing_sub" = "$SUBDOMAIN" ]; then is_broken=true; fi
        if ! docker ps -a -q -f "name=mirza_$b" 2>/dev/null | grep -q . \
           && [ ! -f "$BASE_DIR/$b/files/index.php" ]; then is_broken=true; fi
        if [ "$is_broken" = "true" ]; then
            warn "ربات ناموفق ($b) پیدا شد — در حال پاکسازی..."
            local fb_sub fb_db fb_user
            fb_sub=$(grep "^SUBDOMAIN=" "$bconf" 2>/dev/null | cut -d= -f2 || true)
            fb_db=$(grep "^DB_NAME=" "$bconf" 2>/dev/null | cut -d= -f2 || true)
            fb_user=$(grep "^DB_USER=" "$bconf" 2>/dev/null | cut -d= -f2 || true)
            cd "$BASE_DIR" 2>/dev/null || true
            docker compose stop "$b" 2>/dev/null || true
            docker compose rm -f "$b" 2>/dev/null || true
            [ -n "${fb_sub:-}" ] && rm -f "/etc/nginx/sites-enabled/${fb_sub}.conf" \
                "/etc/nginx/sites-available/${fb_sub}.conf" 2>/dev/null || true
            rm -rf "$BASE_DIR/$b"
            remove_bot_from_list "$b"
            save_master_conf
            success "پاکسازی $b انجام شد."
            break
        fi
    done

    # ── Generate identifiers ──────────────────────────────────
    local BOT_NAME
    BOT_NAME=$(next_bot_name)
    PORT=$(next_free_port)
    DB_NAME="mirza_${BOT_NAME}"
    DB_USER="u$(openssl rand -hex 4)"
    DB_PASS=$(openssl rand -base64 14 | tr -dc 'a-zA-Z0-9' | cut -c1-14)

    local BOT_DIR="$BASE_DIR/$BOT_NAME"
    mkdir -p "$BOT_DIR"

    echo ""
    info "Bot slot  : $BOT_NAME"
    info "Host port : $PORT"
    info "Database  : $DB_NAME"
    echo ""

    # ── Prerequisites ─────────────────────────────────────────
    install_prerequisites

    # ── Bot files ─────────────────────────────────────────────
    download_bot_files "$BOT_DIR"
    create_dockerfile "$BOT_DIR"
    create_config_php "$BOT_DIR"   # uses vars in scope

    # ── جایگزینی نام برند در فایل‌های ربات ──────────────────────
    replace_brand_name "$BOT_DIR/files" "$BRAND_NAME"

    # ── Save bot conf ─────────────────────────────────────────
    save_bot_conf "$BOT_NAME"
    add_bot_to_list "$BOT_NAME"
    save_master_conf

    # ── DB setup ──────────────────────────────────────────────
    append_db_init_sql

    # ── SSL ───────────────────────────────────────────────────
    get_ssl "$SUBDOMAIN"

    # ── Regenerate docker-compose.yml ─────────────────────────
    generate_compose

    # ── Start containers ──────────────────────────────────────
    cd "$BASE_DIR"
    if docker ps -q -f name=mirza_mysql 2>/dev/null | grep -q .; then
        # MySQL already running — just build & start the new bot
        info "MySQL already running. Starting $BOT_NAME ..."
        create_db_live
        docker compose up -d --build "$BOT_NAME"
    else
        # First bot — start everything
        info "Starting all containers (this includes MySQL first-time setup)..."
        docker compose up -d --build
    fi

    wait_healthy "mirza_mysql"

    # ── Nginx ────────────────────────────────────────────────
    create_nginx_conf "$SUBDOMAIN" "$PORT"

    # ── Init DB tables via table.php ──────────────────────────
    info "Initialising database tables..."
    sleep 5
    curl -sk "https://$SUBDOMAIN/table.php" -o /dev/null \
        && success "table.php executed." \
        || warn "table.php unreachable — try visiting https://$SUBDOMAIN/table.php manually."

    # ── Set Telegram webhook ──────────────────────────────────
    info "Setting Telegram webhook..."
    local wh_resp
    wh_resp=$(curl -s "https://api.telegram.org/bot$TOKEN/setWebhook" \
        --data-urlencode "url=https://$SUBDOMAIN/index.php")
    if echo "$wh_resp" | grep -q '"ok":true'; then
        success "Webhook set → https://$SUBDOMAIN/index.php"
    else
        warn "Webhook response: $wh_resp"
    fi

    # ── Summary ───────────────────────────────────────────────
    clear
    echo ""
    echo -e "${G}${BOLD}╔══════════════════════════════════════════╗${W}"
    echo -e "${G}${BOLD}║      Bot Installed Successfully ✅       ║${W}"
    echo -e "${G}${BOLD}╚══════════════════════════════════════════╝${W}"
    echo ""
    echo -e "  ${C}Bot name :${W} $BOT_NAME"
    echo -e "  ${C}Panel URL:${W} https://$SUBDOMAIN"
    echo -e "  ${C}DB name  :${W} $DB_NAME"
    echo -e "  ${C}DB user  :${W} $DB_USER"
    echo -e "  ${C}DB pass  :${W} $DB_PASS"
    echo -e "  ${C}Port     :${W} $PORT (internal)"
    echo ""
    echo -e "  ${Y}Send /start to your bot to begin!${W}"
    echo ""
    read -rp "  Press Enter to return to menu..."
}

# ── 2. List bots ───────────────────────────────────────────────
action_list() {
    clear
    echo -e "${BOLD}${C}══════════════════════════════════════${W}"
    echo -e "${BOLD}${C}         Installed Bots               ${W}"
    echo -e "${BOLD}${C}══════════════════════════════════════${W}"
    echo ""

    list_bots_array
    if [ ${#BOT_LIST[@]} -eq 0 ] || [ -z "${BOT_LIST[0]}" ]; then
        echo -e "  ${Y}No bots installed yet.${W}"
        echo ""
        read -rp "  Press Enter..."; return
    fi

    printf "  %-4s %-8s %-32s %-6s %s\n" "#" "Name" "Subdomain" "Port" "Status"
    echo "  ──────────────────────────────────────────────────────"

    local idx=1
    for b in "${BOT_LIST[@]}"; do
        [ -z "$b" ] && continue
        local bconf="$BASE_DIR/$b/.conf"
        [ -f "$bconf" ] || continue
        local subdomain port
        subdomain=$(grep '^SUBDOMAIN=' "$bconf" | cut -d= -f2)
        port=$(grep '^PORT=' "$bconf" | cut -d= -f2)
        local status="${R}Stopped${W}"
        docker ps -q -f "name=mirza_$b" 2>/dev/null | grep -q . && status="${G}Running${W}"
        printf "  %-4s %-8s %-32s %-6s " "$idx" "$b" "$subdomain" "$port"
        echo -e "$status"
        ((idx++))
    done

    echo ""
    read -rp "  Press Enter..."
}

# ── 3. Update all bots ─────────────────────────────────────────
action_update() {
    clear
    echo -e "${BOLD}${C}══════════════════════════════════════${W}"
    echo -e "${BOLD}${C}         Update All Bots ♻️            ${W}"
    echo -e "${BOLD}${C}══════════════════════════════════════${W}"
    echo ""

    list_bots_array
    if [ ${#BOT_LIST[@]} -eq 0 ] || [ -z "${BOT_LIST[0]}" ]; then
        echo -e "  ${Y}No bots to update.${W}"; read -rp "  Press Enter..."; return
    fi

    for b in "${BOT_LIST[@]}"; do
        [ -z "$b" ] && continue
        local bot_dir="$BASE_DIR/$b"
        [ -d "$bot_dir" ] || continue

        info "Updating $b ..."
        # Backup config
        cp "$bot_dir/config.php" "/tmp/.${b}_config.bak"
        # Re-download files
        download_bot_files "$bot_dir"
        # Restore config
        cp "/tmp/.${b}_config.bak" "$bot_dir/config.php"
        rm -f "/tmp/.${b}_config.bak"
        success "$b source updated."
    done

    info "Rebuilding containers..."
    cd "$BASE_DIR"
    generate_compose
    docker compose up -d --build

    # Re-run table.php
    for b in "${BOT_LIST[@]}"; do
        [ -z "$b" ] && continue
        local bconf="$BASE_DIR/$b/.conf"
        [ -f "$bconf" ] || continue
        local subdomain
        subdomain=$(grep '^SUBDOMAIN=' "$bconf" | cut -d= -f2)
        sleep 3
        curl -sk "https://$subdomain/table.php" -o /dev/null \
            && success "$b tables updated." \
            || warn "$b table.php unreachable — try manually."
    done

    echo ""; success "All bots updated."
    read -rp "  Press Enter..."
}

# ── 4. Remove a bot ────────────────────────────────────────────
action_remove() {
    clear
    echo -e "${BOLD}${C}══════════════════════════════════════${W}"
    echo -e "${BOLD}${C}           Remove a Bot 🗑️             ${W}"
    echo -e "${BOLD}${C}══════════════════════════════════════${W}"
    echo ""

    list_bots_array
    if [ ${#BOT_LIST[@]} -eq 0 ] || [ -z "${BOT_LIST[0]}" ]; then
        echo -e "  ${Y}No bots installed.${W}"; read -rp "  Press Enter..."; return
    fi

    # Print list
    local idx=1
    for b in "${BOT_LIST[@]}"; do
        [ -z "$b" ] && continue
        local bconf="$BASE_DIR/$b/.conf"
        [ -f "$bconf" ] || continue
        local subdomain
        subdomain=$(grep '^SUBDOMAIN=' "$bconf" | cut -d= -f2)
        echo -e "  ${C}$idx)${W} $b  ($subdomain)"
        ((idx++))
    done
    echo ""

    read -rp "  Bot number to remove (0 = cancel): " sel
    [[ "$sel" = "0" ]] && return
    [[ ! "$sel" =~ ^[0-9]+$ ]] && { warn "Invalid."; return; }

    local target_bot="${BOT_LIST[$((sel-1))]}"
    [ -z "${target_bot:-}" ] && { warn "Invalid selection."; return; }

    load_bot_conf "$target_bot"   # sets SUBDOMAIN, PORT, DB_NAME, DB_USER, DB_PASS, TOKEN

    echo ""
    echo -e "${R}  About to permanently remove: $target_bot ($SUBDOMAIN)${W}"
    read -rp "  Type YES to confirm: " confirm
    [[ "$confirm" != "YES" ]] && { info "Cancelled."; read -rp "  Press Enter..."; return; }

    # Stop & remove container
    info "Stopping container mirza_$target_bot ..."
    cd "$BASE_DIR"
    docker compose stop "$target_bot" 2>/dev/null || true
    docker compose rm -f "$target_bot" 2>/dev/null || true

    # Nginx
    remove_nginx_conf "$SUBDOMAIN"

    # Drop database
    if docker ps -q -f name=mirza_mysql 2>/dev/null | grep -q .; then
        docker exec mirza_mysql mysql -uroot -p"$MYSQL_ROOT_PASS" -e "
            DROP DATABASE IF EXISTS \`$DB_NAME\`;
            DROP USER IF EXISTS '$DB_USER'@'%';
            FLUSH PRIVILEGES;
        " 2>/dev/null && success "Database $DB_NAME dropped." || warn "Could not drop database."
    fi

    # Remove files
    rm -rf "$BASE_DIR/$target_bot"

    # Update state
    remove_bot_from_list "$target_bot"
    save_master_conf
    generate_compose

    success "$target_bot removed."
    echo ""; read -rp "  Press Enter..."
}

# ── 5. Backup databases ────────────────────────────────────────
action_backup() {
    clear
    echo -e "${BOLD}${C}══════════════════════════════════════${W}"
    echo -e "${BOLD}${C}        Backup Databases 💾           ${W}"
    echo -e "${BOLD}${C}══════════════════════════════════════${W}"
    echo ""

    if ! docker ps -q -f name=mirza_mysql 2>/dev/null | grep -q .; then
        warn "MySQL container is not running."; read -rp "  Press Enter..."; return
    fi

    local backup_dir="/root/mirza-backups/$(date +%Y%m%d_%H%M%S)"
    mkdir -p "$backup_dir"

    list_bots_array
    for b in "${BOT_LIST[@]}"; do
        [ -z "$b" ] && continue
        local bconf="$BASE_DIR/$b/.conf"
        [ -f "$bconf" ] || continue
        local db
        db=$(grep '^DB_NAME=' "$bconf" | cut -d= -f2)
        info "Backing up $b ($db) ..."
        docker exec mirza_mysql mysqldump -uroot -p"$MYSQL_ROOT_PASS" "$db" \
            > "$backup_dir/${b}.sql" 2>/dev/null \
            && success "  Saved: $backup_dir/${b}.sql" \
            || warn "  Failed to backup $b."
    done

    echo ""
    success "Backups saved to: $backup_dir"
    read -rp "  Press Enter..."
}

# ── 6. Docker status ───────────────────────────────────────────
action_status() {
    clear
    echo -e "${BOLD}${C}══════════════════════════════════════${W}"
    echo -e "${BOLD}${C}         Docker Status 🐳             ${W}"
    echo -e "${BOLD}${C}══════════════════════════════════════${W}"
    echo ""
    cd "$BASE_DIR" 2>/dev/null || true
    docker compose ps 2>/dev/null || docker ps
    echo ""
    echo -e "${C}Resource usage:${W}"
    docker stats --no-stream --format \
        "  {{.Name}}\tCPU: {{.CPUPerc}}\tRAM: {{.MemUsage}}" 2>/dev/null || true
    echo ""
    read -rp "  Press Enter..."
}

# ══════════════════════════════════════════════════════════════
# LOGO & MAIN MENU
# ══════════════════════════════════════════════════════════════

show_logo() {
    clear
    echo -e "${BOLD}${B}"
    cat << 'LOGO'
  ███╗   ███╗██╗██████╗ ███████╗ █████╗
  ████╗ ████║██║██╔══██╗╚══███╔╝██╔══██╗
  ██╔████╔██║██║██████╔╝  ███╔╝ ███████║
  ██║╚██╔╝██║██║██╔══██╗ ███╔╝  ██╔══██║
  ██║ ╚═╝ ██║██║██║  ██║███████╗██║  ██║
  ╚═╝     ╚═╝╚═╝╚═╝  ╚═╝╚══════╝╚═╝  ╚═╝
  ██████╗  ██████╗  ██████╗██╗  ██╗███████╗██████╗
  ██╔══██╗██╔═══██╗██╔════╝██║ ██╔╝██╔════╝██╔══██╗
  ██║  ██║██║   ██║██║     █████╔╝ █████╗  ██████╔╝
  ██║  ██║██║   ██║██║     ██╔═██╗ ██╔══╝  ██╔══██╗
  ██████╔╝╚██████╔╝╚██████╗██║  ██╗███████╗██║  ██║
  ╚═════╝  ╚═════╝  ╚═════╝╚═╝  ╚═╝╚══════╝╚═╝  ╚═╝
LOGO
    echo -e "${W}"
    echo -e "  ${BOLD}Docker Edition${W}  |  Bots installed: ${G}$(bot_count)${W}"
    echo ""

    # Quick status
    list_bots_array
    if [ ${#BOT_LIST[@]} -gt 0 ] && [ -n "${BOT_LIST[0]}" ]; then
        for b in "${BOT_LIST[@]}"; do
            [ -z "$b" ] && continue
            local bconf="$BASE_DIR/$b/.conf"
            [ -f "$bconf" ] || continue
            local sub
            sub=$(grep '^SUBDOMAIN=' "$bconf" | cut -d= -f2)
            local dot="${R}●${W}"
            docker ps -q -f "name=mirza_$b" 2>/dev/null | grep -q . && dot="${G}●${W}"
            echo -e "  $dot $b → $sub"
        done
    fi

    echo ""
    echo -e "  ${B}────────────────────────────────────────${W}"
}

main_menu() {
    while true; do
        show_logo
        echo -e "  ${C}1)${W} Install New Bot"
        echo -e "  ${C}2)${W} List Bots"
        echo -e "  ${C}3)${W} Update All Bots"
        echo -e "  ${C}4)${W} Remove a Bot"
        echo -e "  ${C}5)${W} Backup Databases"
        echo -e "  ${C}6)${W} Docker Status"
        echo -e "  ${C}7)${W} Exit"
        echo ""
        read -rp "  Select [1-7]: " opt

        case "$opt" in
            1) action_install ;;
            2) action_list ;;
            3) action_update ;;
            4) action_remove ;;
            5) action_backup ;;
            6) action_status ;;
            7) echo -e "${G}Goodbye!${W}"; exit 0 ;;
            *) warn "Invalid option."; sleep 1 ;;
        esac
    done
}

# ══════════════════════════════════════════════════════════════
# ENTRY POINT
# ══════════════════════════════════════════════════════════════
main() {
    # Install self as system command: mirza
    if [ "$0" != "$MASTER_PATH" ]; then
        cp -f "$0" "$MASTER_PATH"
        chmod +x "$MASTER_PATH"
    fi
    ln -sf "$MASTER_PATH" "$BIN_LINK" 2>/dev/null || true

    # Check for updates from GitHub
    self_update "$@"

    load_master_conf

    main_menu
}

main "$@"
