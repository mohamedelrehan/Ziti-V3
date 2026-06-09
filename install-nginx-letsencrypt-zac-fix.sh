#!/usr/bin/env bash
set -Eeuo pipefail

# Generic NGINX + Let's Encrypt + OpenZiti ZAC assets fix
# Run AFTER the OpenZiti controller/ZAC has been installed and validated.
#
# Usage:
#   sudo DOMAIN_NAME='ziti.example.com' \
#        ADMIN_EMAIL='admin@example.com' \
#        ./install-nginx-letsencrypt-zac-fix.sh
#
# Optional:
#   ZITI_CONTROLLER_HOST='127.0.0.1'
#   ZITI_CONTROLLER_PORT='1280'
#   CERTBOT_STAGING='true'           # use Let's Encrypt staging for tests
#   ENABLE_HSTS='false'              # default false

DOMAIN_NAME="${DOMAIN_NAME:-}"
ADMIN_EMAIL="${ADMIN_EMAIL:-}"
ZITI_CONTROLLER_HOST="${ZITI_CONTROLLER_HOST:-127.0.0.1}"
ZITI_CONTROLLER_PORT="${ZITI_CONTROLLER_PORT:-1280}"
CERTBOT_STAGING="${CERTBOT_STAGING:-false}"
ENABLE_HSTS="${ENABLE_HSTS:-false}"

NGINX_SITE_AVAILABLE="/etc/nginx/sites-available/default"
NGINX_SITE_ENABLED="/etc/nginx/sites-enabled/default"

log() { printf '\n[INFO] %s\n' "$*"; }
warn() { printf '\n[WARN] %s\n' "$*" >&2; }
fail() { printf '\n[ERROR] %s\n' "$*" >&2; exit 1; }

require_root() {
  [[ "${EUID}" -eq 0 ]] || fail "Run with sudo."
}

require_apt() {
  command -v apt >/dev/null 2>&1 || fail "This script requires apt. Use Ubuntu/Debian."
}

collect_inputs() {
  if [[ -z "$DOMAIN_NAME" ]]; then
    printf "Enter public FQDN, for example ziti.example.com: "
    read -r DOMAIN_NAME
  fi
  [[ -n "$DOMAIN_NAME" ]] || fail "DOMAIN_NAME is required."

  if [[ -z "$ADMIN_EMAIL" ]]; then
    printf "Enter admin email for Let's Encrypt renewal notices: "
    read -r ADMIN_EMAIL
  fi
  [[ -n "$ADMIN_EMAIL" ]] || fail "ADMIN_EMAIL is required."
}

validate_inputs() {
  log "Validating domain and local controller"

  if [[ "$DOMAIN_NAME" =~ ^https?:// ]]; then
    fail "DOMAIN_NAME must be hostname only, not URL. Example: ziti.example.com"
  fi

  [[ "$DOMAIN_NAME" =~ ^[A-Za-z0-9.-]+$ ]] || fail "Invalid DOMAIN_NAME: $DOMAIN_NAME"

  if ! getent hosts "$DOMAIN_NAME" >/dev/null; then
    fail "Domain does not resolve from this VM: $DOMAIN_NAME"
  fi

  local dns_ip public_ip
  dns_ip="$(getent ahostsv4 "$DOMAIN_NAME" | awk '{print $1}' | head -n1 || true)"
  public_ip="$(curl -4fsS https://api.ipify.org || true)"

  log "Domain IPv4: ${dns_ip:-unknown}"
  log "VM public IPv4: ${public_ip:-unknown}"

  if [[ -n "$dns_ip" && -n "$public_ip" && "$dns_ip" != "$public_ip" ]]; then
    fail "Domain resolves to ${dns_ip}, but this VM public IP is ${public_ip}. Fix DNS first."
  fi

  curl -kfsS "https://${ZITI_CONTROLLER_HOST}:${ZITI_CONTROLLER_PORT}/zac/" >/dev/null || \
    fail "Local OpenZiti ZAC is not reachable at https://${ZITI_CONTROLLER_HOST}:${ZITI_CONTROLLER_PORT}/zac/"
}

install_packages() {
  log "Installing NGINX and Certbot"

  apt update
  DEBIAN_FRONTEND=noninteractive apt install -y nginx certbot python3-certbot-nginx curl ca-certificates
}

ensure_nginx_running_for_http_challenge() {
  log "Starting NGINX for Let's Encrypt HTTP challenge"

  systemctl enable nginx >/dev/null
  systemctl restart nginx

  sleep 2
  systemctl is-active --quiet nginx || {
    systemctl status nginx --no-pager -l || true
    fail "nginx is not active."
  }
}

obtain_certificate() {
  log "Requesting Let's Encrypt certificate for ${DOMAIN_NAME}"

  local staging_arg=()
  if [[ "$CERTBOT_STAGING" == "true" ]]; then
    warn "CERTBOT_STAGING=true. Certificate will not be browser-trusted."
    staging_arg=(--staging)
  fi

  certbot --nginx \
    --non-interactive \
    --agree-tos \
    --email "$ADMIN_EMAIL" \
    --redirect \
    -d "$DOMAIN_NAME" \
    "${staging_arg[@]}"

  [[ -f "/etc/letsencrypt/live/${DOMAIN_NAME}/fullchain.pem" ]] || fail "Certificate fullchain not found."
  [[ -f "/etc/letsencrypt/live/${DOMAIN_NAME}/privkey.pem" ]] || fail "Certificate private key not found."
}

backup_nginx_config() {
  local ts
  ts="$(date -u +%Y%m%dT%H%M%SZ)"
  log "Backing up NGINX config to ${NGINX_SITE_AVAILABLE}.bak-${ts}"
  cp "$NGINX_SITE_AVAILABLE" "${NGINX_SITE_AVAILABLE}.bak-${ts}"
}

write_nginx_proxy_config() {
  log "Writing NGINX reverse proxy config with ZAC /assets fix"

  local hsts_line=""
  if [[ "$ENABLE_HSTS" == "true" ]]; then
    hsts_line='    add_header Strict-Transport-Security "max-age=31536000; includeSubDomains" always;'
  fi

  cat > "$NGINX_SITE_AVAILABLE" <<EOF_NGINX
server {
    listen 80;
    listen [::]:80;
    server_name ${DOMAIN_NAME};

    return 301 https://\$host\$request_uri;
}

server {
    listen 443 ssl;
    listen [::]:443 ssl;
    server_name ${DOMAIN_NAME};

    ssl_certificate /etc/letsencrypt/live/${DOMAIN_NAME}/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/${DOMAIN_NAME}/privkey.pem;
    include /etc/letsencrypt/options-ssl-nginx.conf;
${hsts_line}

    # ZAC currently requests some static assets from /assets/*.
    # The OpenZiti controller serves those assets under /zac/assets/*.
    # This fixes missing icons, fonts, SVGs, and Lottie animations.
    location /assets/ {
        proxy_pass https://${ZITI_CONTROLLER_HOST}:${ZITI_CONTROLLER_PORT}/zac/assets/;
        proxy_ssl_verify off;

        proxy_set_header Host \$host;
        proxy_set_header X-Forwarded-Proto https;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
    }

    location / {
        proxy_pass https://${ZITI_CONTROLLER_HOST}:${ZITI_CONTROLLER_PORT};
        proxy_ssl_verify off;

        proxy_http_version 1.1;
        proxy_set_header Host \$host;
        proxy_set_header X-Forwarded-Proto https;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
    }
}
EOF_NGINX

  if [[ ! -e "$NGINX_SITE_ENABLED" ]]; then
    ln -s "$NGINX_SITE_AVAILABLE" "$NGINX_SITE_ENABLED"
  fi
}

validate_nginx() {
  log "Testing and reloading NGINX"
  nginx -t
  systemctl reload nginx
}

validate_certbot_timer() {
  log "Checking Certbot auto-renew timer"
  systemctl list-timers --all | grep -E 'certbot|snap.certbot' || warn "Certbot timer not shown. Check systemd timers manually."
}

validate_public_urls() {
  log "Validating public HTTPS and ZAC asset fix"

  curl -fsSI "https://${DOMAIN_NAME}/zac/" >/dev/null || fail "Public ZAC URL failed: https://${DOMAIN_NAME}/zac/"
  curl -fsSI "https://${DOMAIN_NAME}/assets/fonts/icomoon.woff2" >/dev/null || fail "ZAC font asset fix failed."
  curl -fsSI "https://${DOMAIN_NAME}/assets/animations/Loader.json" >/dev/null || fail "ZAC animation asset fix failed."
  curl -fsSI "https://${DOMAIN_NAME}/assets/svgs/ziti-logo.svg" >/dev/null || fail "ZAC SVG asset fix failed."

  log "Public ZAC asset checks passed."
}

print_summary() {
  cat <<EOF_SUMMARY

============================================================
NGINX + Let's Encrypt + ZAC asset fix completed.
============================================================

Browser URL:
  https://${DOMAIN_NAME}/zac/

Direct controller URL:
  https://${DOMAIN_NAME}:${ZITI_CONTROLLER_PORT}/zac/

Certificate:
  /etc/letsencrypt/live/${DOMAIN_NAME}/fullchain.pem
  /etc/letsencrypt/live/${DOMAIN_NAME}/privkey.pem

Important checks:
  sudo nginx -t
  sudo systemctl status nginx --no-pager -l
  sudo certbot certificates
  sudo certbot renew --dry-run
  curl -I https://${DOMAIN_NAME}/assets/fonts/icomoon.woff2
  curl -I https://${DOMAIN_NAME}/assets/animations/Loader.json
  curl -I https://${DOMAIN_NAME}/assets/svgs/ziti-logo.svg

Rollback:
  Restore one of the backups:
    sudo cp /etc/nginx/sites-available/default.bak-<timestamp> /etc/nginx/sites-available/default
    sudo nginx -t
    sudo systemctl reload nginx

============================================================

EOF_SUMMARY
}

main() {
  require_root
  require_apt
  collect_inputs
  validate_inputs
  install_packages
  ensure_nginx_running_for_http_challenge
  obtain_certificate
  backup_nginx_config
  write_nginx_proxy_config
  validate_nginx
  validate_certbot_timer
  validate_public_urls
  print_summary
}

main "$@"
