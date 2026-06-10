#!/usr/bin/env bash
set -Eeuo pipefail

# Azure Custom Script Extension bootstrap for OpenZiti V3.
#
# Args:
#   1 Azure FQDN
#   2 OpenZiti admin username
#   3 OpenZiti admin password base64
#   4 Lets Encrypt email
#   5 install nginx/letsencrypt true|false
#   6 run apt upgrade true|false
#   7 repo raw base URL

exec > >(tee -a /var/log/ziti-v3-bootstrap.log) 2>&1

AZURE_FQDN="${1:?missing Azure FQDN}"
ZITI_USER="${2:?missing OpenZiti user}"
ZITI_PWD_B64="${3:?missing OpenZiti password b64}"
LE_EMAIL="${4:?missing Lets Encrypt email}"
INSTALL_NGINX_LE="${5:-true}"
RUN_APT_UPGRADE="${6:-true}"
REPO_RAW_BASE_URL="${7:-https://raw.githubusercontent.com/mohamedelrehan/Ziti-V3/main}"

ZITI_PWD="$(printf "%s" "$ZITI_PWD_B64" | base64 -d)"

echo "[INFO] Starting Ziti V3 bootstrap at $(date -Is)"
echo "[INFO] Azure FQDN: ${AZURE_FQDN}"
echo "[INFO] Repo raw base URL: ${REPO_RAW_BASE_URL}"
echo "[INFO] Install NGINX and Lets Encrypt: ${INSTALL_NGINX_LE}"
echo "[INFO] Run apt upgrade: ${RUN_APT_UPGRADE}"

mkdir -p /opt/ziti-v3
cd /opt/ziti-v3

echo "[INFO] Installing base tools"
apt-get update
DEBIAN_FRONTEND=noninteractive apt-get install -y curl ca-certificates jq dnsutils

echo "[INFO] Downloading OpenZiti scripts"
curl -fsSL "${REPO_RAW_BASE_URL}/install-openziti-v2-controller-zac.sh" -o install-openziti-v2-controller-zac.sh
curl -fsSL "${REPO_RAW_BASE_URL}/install-nginx-letsencrypt-zac-fix.sh" -o install-nginx-letsencrypt-zac-fix.sh

chmod +x install-openziti-v2-controller-zac.sh
chmod +x install-nginx-letsencrypt-zac-fix.sh

echo "[INFO] Waiting for Azure DNS to resolve"
for i in $(seq 1 60); do
  if getent hosts "${AZURE_FQDN}" >/dev/null; then
    getent hosts "${AZURE_FQDN}"
    break
  fi
  echo "[INFO] DNS not ready yet: ${AZURE_FQDN} check ${i}/60"
  sleep 10
done

echo "[INFO] Installing OpenZiti controller"
ZITI_DNS="${AZURE_FQDN}" \
ZITI_USER="${ZITI_USER}" \
ZITI_PWD="${ZITI_PWD}" \
RUN_APT_UPGRADE="${RUN_APT_UPGRADE}" \
SKIP_DNS_IP_MATCH="true" \
./install-openziti-v2-controller-zac.sh

echo "[INFO] Writing helper to rerun NGINX and Lets Encrypt later"
cat > /opt/ziti-v3/run-nginx-letsencrypt-later.sh <<EOF_LATER
#!/usr/bin/env bash
set -Eeuo pipefail
cd /opt/ziti-v3
sudo DOMAIN_NAME="${AZURE_FQDN}" ADMIN_EMAIL="${LE_EMAIL}" ./install-nginx-letsencrypt-zac-fix.sh
EOF_LATER

chmod +x /opt/ziti-v3/run-nginx-letsencrypt-later.sh

if [[ "${INSTALL_NGINX_LE}" == "true" ]]; then
  echo "[INFO] Installing NGINX, Lets Encrypt, and ZAC fix"
  DOMAIN_NAME="${AZURE_FQDN}" \
  ADMIN_EMAIL="${LE_EMAIL}" \
  ./install-nginx-letsencrypt-zac-fix.sh
else
  echo "[INFO] Skipping NGINX and Lets Encrypt because installNginxLetsEncrypt=false"
fi

echo "[INFO] Final local checks"
systemctl status ziti-controller --no-pager -l || true
curl -kfsS "https://127.0.0.1:1280/zac/" | head || true

echo "[INFO] Bootstrap finished at $(date -Is)"
