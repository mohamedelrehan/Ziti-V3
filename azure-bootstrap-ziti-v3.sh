#!/usr/bin/env bash
set -Eeuo pipefail

# Azure Custom Script Extension bootstrap for OpenZiti V3.
#
# Enterprise-safe behavior:
# - Do NOT block OpenZiti controller installation on Azure DNS propagation.
# - Install controller immediately using the expected Azure FQDN.
# - Wait for DNS only before running NGINX + Lets Encrypt.
# - If DNS is not ready, leave controller running on :1280 and create a rerun helper.

exec > >(tee -a /var/log/ziti-v3-bootstrap.log) 2>&1

AZURE_FQDN="${1:?missing Azure FQDN}"
ZITI_USER="${2:?missing OpenZiti user}"
ZITI_PWD_B64="${3:?missing OpenZiti password b64}"
LE_EMAIL="${4:?missing Lets Encrypt email}"
INSTALL_NGINX_LE="${5:-true}"
RUN_APT_UPGRADE="${6:-true}"
REPO_RAW_BASE_URL="${7:-https://raw.githubusercontent.com/mohamedelrehan/Ziti-V3/main}"

ZITI_PWD="$(printf "%s" "$ZITI_PWD_B64" | base64 -d)"

log() { printf '\n[INFO] %s\n' "$*"; }
warn() { printf '\n[WARN] %s\n' "$*" >&2; }
fail() { printf '\n[ERROR] %s\n' "$*" >&2; exit 1; }

dns_points_to_this_vm() {
  local fqdn="$1"
  local dns_ip public_ip

  dns_ip="$(getent ahostsv4 "$fqdn" | awk '{print $1}' | head -n1 || true)"
  public_ip="$(curl -4fsS https://api.ipify.org || true)"

  log "DNS check: ${fqdn}=${dns_ip:-unresolved}, vm_public_ip=${public_ip:-unknown}"

  [[ -n "$dns_ip" && -n "$public_ip" && "$dns_ip" == "$public_ip" ]]
}

wait_for_dns_for_cert() {
  local fqdn="$1"
  local attempts="${2:-60}"
  local sleep_seconds="${3:-20}"

  log "Waiting for DNS before Lets Encrypt: ${fqdn}"

  for i in $(seq 1 "$attempts"); do
    if dns_points_to_this_vm "$fqdn"; then
      log "DNS is ready for Lets Encrypt."
      return 0
    fi

    warn "DNS not ready for certificate yet: ${fqdn} attempt ${i}/${attempts}"
    sleep "$sleep_seconds"
  done

  return 1
}

log "Starting Ziti V3 bootstrap at $(date -Is)"
log "Azure FQDN: ${AZURE_FQDN}"
log "Repo raw base URL: ${REPO_RAW_BASE_URL}"
log "Install NGINX and Lets Encrypt: ${INSTALL_NGINX_LE}"
log "Run apt upgrade: ${RUN_APT_UPGRADE}"

mkdir -p /opt/ziti-v3
cd /opt/ziti-v3

log "Installing base tools"
apt-get update
DEBIAN_FRONTEND=noninteractive apt-get install -y curl ca-certificates jq dnsutils

log "Downloading OpenZiti scripts"
curl -fsSL "${REPO_RAW_BASE_URL}/install-openziti-v2-controller-zac.sh" -o install-openziti-v2-controller-zac.sh
curl -fsSL "${REPO_RAW_BASE_URL}/install-nginx-letsencrypt-zac-fix.sh" -o install-nginx-letsencrypt-zac-fix.sh

chmod +x install-openziti-v2-controller-zac.sh
chmod +x install-nginx-letsencrypt-zac-fix.sh

log "Writing helper scripts"

cat > /opt/ziti-v3/run-nginx-letsencrypt-later.sh <<EOF_LATER
#!/usr/bin/env bash
set -Eeuo pipefail
cd /opt/ziti-v3
sudo DOMAIN_NAME="${AZURE_FQDN}" ADMIN_EMAIL="${LE_EMAIL}" ./install-nginx-letsencrypt-zac-fix.sh
EOF_LATER
chmod +x /opt/ziti-v3/run-nginx-letsencrypt-later.sh

cat > /opt/ziti-v3/check-ziti-v3.sh <<EOF_CHECK
#!/usr/bin/env bash
set -Eeuo pipefail
echo "=== Ziti controller service ==="
sudo systemctl status ziti-controller --no-pager -l || true
echo
echo "=== Listening ports ==="
sudo ss -tulpn | egrep '1280|443|80' || true
echo
echo "=== Local ZAC ==="
curl -kI https://127.0.0.1:1280/zac/ || true
echo
echo "=== NGINX ==="
sudo systemctl status nginx --no-pager -l || true
echo
echo "=== Public ZAC ==="
curl -I https://${AZURE_FQDN}/zac/ || true
echo
echo "=== Assets ==="
curl -I https://${AZURE_FQDN}/assets/fonts/icomoon.woff2 || true
curl -I https://${AZURE_FQDN}/assets/animations/Loader.json || true
curl -I https://${AZURE_FQDN}/assets/svgs/ziti-logo.svg || true
EOF_CHECK
chmod +x /opt/ziti-v3/check-ziti-v3.sh

log "Installing OpenZiti controller immediately. DNS propagation is not required for this step."
ZITI_DNS="${AZURE_FQDN}" \
ZITI_USER="${ZITI_USER}" \
ZITI_PWD="${ZITI_PWD}" \
RUN_APT_UPGRADE="${RUN_APT_UPGRADE}" \
SKIP_DNS_IP_MATCH="true" \
./install-openziti-v2-controller-zac.sh

log "Controller installation completed or script returned successfully."

log "Validating local controller before certificate step"
systemctl status ziti-controller --no-pager -l || true
curl -kfsS "https://127.0.0.1:1280/zac/" >/dev/null || fail "Local ZAC is not reachable after controller install."

if [[ "${INSTALL_NGINX_LE}" == "true" ]]; then
  log "NGINX and Lets Encrypt requested."
  if wait_for_dns_for_cert "${AZURE_FQDN}" 60 20; then
    log "Installing NGINX, Lets Encrypt, and ZAC asset fix"
    DOMAIN_NAME="${AZURE_FQDN}" \
    ADMIN_EMAIL="${LE_EMAIL}" \
    ./install-nginx-letsencrypt-zac-fix.sh
  else
    warn "DNS was not ready for Lets Encrypt within timeout."
    warn "OpenZiti controller is still installed and should be reachable on port 1280."
    warn "After DNS resolves, run: sudo /opt/ziti-v3/run-nginx-letsencrypt-later.sh"
  fi
else
  warn "Skipping NGINX and Lets Encrypt because installNginxLetsEncrypt=false"
  warn "To enable later, run: sudo /opt/ziti-v3/run-nginx-letsencrypt-later.sh"
fi

log "Final checks"
systemctl status ziti-controller --no-pager -l || true
curl -kI "https://127.0.0.1:1280/zac/" || true
systemctl status nginx --no-pager -l || true

log "Bootstrap finished at $(date -Is)"
log "Run health check anytime with: sudo /opt/ziti-v3/check-ziti-v3.sh"
