#!/usr/bin/env bash
set -Eeuo pipefail

# Generic OpenZiti v2 Controller + ZAC installer
# Ubuntu/Debian apt-based systems. Intended for a CLEAN controller VM.
#
# Usage:
#   sudo ZITI_DNS='ziti.example.com' \
#        ZITI_USER='admin' \
#        ZITI_PWD='StrongPasswordHere' \
#        ./install-openziti-v2-controller-zac.sh
#
# Optional:
#   OPENZITI_VERSION='2.0.0'        # default: latest-2
#   CONSOLE_VERSION='4.2.0'         # default: latest
#   ZITI_PORT='1280'                # default: 1280
#   RUN_APT_UPGRADE='true'          # default: false
#   HOLD_PACKAGES='true'            # default: true
#   SKIP_DNS_IP_MATCH='true'        # default: false
#   FORCE_CLEAN_INSTALL='true'      # default: false, deletes existing controller state

OPENZITI_VERSION="${OPENZITI_VERSION:-latest-2}"
CONSOLE_VERSION="${CONSOLE_VERSION:-latest}"
ZITI_DNS="${ZITI_DNS:-}"
ZITI_PORT="${ZITI_PORT:-1280}"
ZITI_USER="${ZITI_USER:-admin}"
ZITI_PWD="${ZITI_PWD:-}"
ZITI_CLUSTER_NODE_NAME="${ZITI_CLUSTER_NODE_NAME:-}"
ZITI_CLUSTER_TRUST_DOMAIN="${ZITI_CLUSTER_TRUST_DOMAIN:-}"
RUN_APT_UPGRADE="${RUN_APT_UPGRADE:-false}"
HOLD_PACKAGES="${HOLD_PACKAGES:-true}"
SKIP_DNS_IP_MATCH="${SKIP_DNS_IP_MATCH:-false}"
FORCE_CLEAN_INSTALL="${FORCE_CLEAN_INSTALL:-false}"

OPENZITI_LIST_FILE="/etc/apt/sources.list.d/openziti-release.list"
OPENZITI_KEYRING="/usr/share/keyrings/openziti.gpg"
BOOTSTRAP_ANSWERS="/tmp/openziti-controller-bootstrap-answers.env"
CONTROLLER_DIR="/var/lib/ziti-controller"

log() { printf '\n[INFO] %s\n' "$*"; }
warn() { printf '\n[WARN] %s\n' "$*" >&2; }
fail() { printf '\n[ERROR] %s\n' "$*" >&2; exit 1; }

cleanup() {
  if [[ -f "$BOOTSTRAP_ANSWERS" ]]; then
    chmod 600 "$BOOTSTRAP_ANSWERS" 2>/dev/null || true
  fi
}
trap cleanup EXIT

require_root() {
  [[ "${EUID}" -eq 0 ]] || fail "Run with sudo."
}

require_apt() {
  command -v apt >/dev/null 2>&1 || fail "This script requires apt. Use Ubuntu/Debian."
}

collect_inputs() {
  if [[ -z "$ZITI_DNS" ]]; then
    printf "Enter controller DNS name, for example ziti.example.com: "
    read -r ZITI_DNS
  fi
  [[ -n "$ZITI_DNS" ]] || fail "ZITI_DNS is required."

  if [[ -z "$ZITI_PWD" ]]; then
    printf "Enter OpenZiti admin password for user '%s': " "$ZITI_USER"
    read -r -s ZITI_PWD
    printf '\n'
  fi
  [[ -n "$ZITI_PWD" ]] || fail "ZITI_PWD is required."
}

validate_dns() {
  log "Validating DNS: ${ZITI_DNS}"

  if [[ "$ZITI_DNS" =~ ^https?:// ]]; then
    fail "ZITI_DNS must be hostname only, not URL. Example: ziti.example.com"
  fi

  [[ "$ZITI_DNS" =~ ^[A-Za-z0-9.-]+$ ]] || fail "Invalid DNS hostname: ${ZITI_DNS}"

  if ! getent hosts "$ZITI_DNS" >/dev/null; then
    fail "DNS name does not resolve from this VM: ${ZITI_DNS}"
  fi

  local dns_ip public_ip
  dns_ip="$(getent ahostsv4 "$ZITI_DNS" | awk '{print $1}' | head -n1 || true)"
  public_ip="$(curl -4fsS https://api.ipify.org || true)"

  log "DNS IPv4: ${dns_ip:-unknown}"
  log "VM public IPv4: ${public_ip:-unknown}"

  if [[ "$SKIP_DNS_IP_MATCH" != "true" && -n "$dns_ip" && -n "$public_ip" && "$dns_ip" != "$public_ip" ]]; then
    fail "DNS resolves to ${dns_ip}, but this VM public IP is ${public_ip}. Fix DNS or set SKIP_DNS_IP_MATCH=true."
  fi
}

prepare_system() {
  log "Preparing system packages"
  apt update

  if [[ "$RUN_APT_UPGRADE" == "true" ]]; then
    DEBIAN_FRONTEND=noninteractive apt upgrade -y
  else
    log "Skipping full apt upgrade. Set RUN_APT_UPGRADE=true to enable."
  fi

  DEBIAN_FRONTEND=noninteractive apt install -y \
    curl gpg ca-certificates apt-transport-https jq unzip dnsutils iproute2
}

add_openziti_repo() {
  log "Adding OpenZiti stable apt repository"

  curl -sSLf https://get.openziti.io/tun/package-repos.gpg | \
    gpg --dearmor --yes --output "$OPENZITI_KEYRING"

  chmod a+r "$OPENZITI_KEYRING"

  echo "deb [signed-by=${OPENZITI_KEYRING}] https://packages.openziti.org/zitipax-openziti-deb-stable debian main" \
    > "$OPENZITI_LIST_FILE"

  apt update
}

latest_2x_version_for() {
  local pkg="$1"
  apt-cache madison "$pkg" | awk '{print $3}' | grep -E '^2\.' | sort -Vr | head -n1
}

latest_version_for() {
  local pkg="$1"
  apt-cache madison "$pkg" | awk '{print $3}' | sort -Vr | head -n1
}

version_exists_for() {
  local pkg="$1" version="$2"
  apt-cache madison "$pkg" | awk '{print $3}' | grep -Fx "$version" >/dev/null
}

resolve_versions() {
  if [[ "$OPENZITI_VERSION" == "latest-2" || "$OPENZITI_VERSION" == "latest" ]]; then
    OPENZITI_VERSION="$(latest_2x_version_for openziti-controller || true)"
    [[ -n "$OPENZITI_VERSION" ]] || fail "No OpenZiti 2.x controller package found."
  fi

  if [[ "$CONSOLE_VERSION" == "latest" ]]; then
    CONSOLE_VERSION="$(latest_version_for openziti-console || true)"
    [[ -n "$CONSOLE_VERSION" ]] || fail "No openziti-console package found."
  fi

  version_exists_for openziti "$OPENZITI_VERSION" || fail "openziti version not found: $OPENZITI_VERSION"
  version_exists_for openziti-controller "$OPENZITI_VERSION" || fail "openziti-controller version not found: $OPENZITI_VERSION"
  version_exists_for openziti-router "$OPENZITI_VERSION" || fail "openziti-router version not found: $OPENZITI_VERSION"
  version_exists_for openziti-console "$CONSOLE_VERSION" || fail "openziti-console version not found: $CONSOLE_VERSION"

  log "Resolved OpenZiti version: $OPENZITI_VERSION"
  log "Resolved ZAC/openziti-console version: $CONSOLE_VERSION"
}

check_existing_install() {
  if [[ -d "$CONTROLLER_DIR" && "$FORCE_CLEAN_INSTALL" != "true" ]]; then
    fail "Existing controller state found at $CONTROLLER_DIR. Use a clean VM or set FORCE_CLEAN_INSTALL=true."
  fi

  if [[ "$FORCE_CLEAN_INSTALL" == "true" ]]; then
    warn "FORCE_CLEAN_INSTALL=true. Removing existing OpenZiti controller state."
    systemctl stop ziti-controller.service 2>/dev/null || true
    rm -rf /var/lib/ziti-controller /var/lib/private/ziti-controller
  fi
}

install_openziti_packages() {
  log "Installing OpenZiti packages"

  DEBIAN_FRONTEND=noninteractive apt install -y \
    "openziti=${OPENZITI_VERSION}" \
    "openziti-controller=${OPENZITI_VERSION}" \
    "openziti-router=${OPENZITI_VERSION}" \
    "openziti-console=${CONSOLE_VERSION}"

  if [[ "$HOLD_PACKAGES" == "true" ]]; then
    log "Pinning installed OpenZiti package versions"
    apt-mark hold openziti openziti-controller openziti-router openziti-console
  fi
}

derive_bootstrap_defaults() {
  if [[ -z "$ZITI_CLUSTER_NODE_NAME" ]]; then
    ZITI_CLUSTER_NODE_NAME="$(hostname -s 2>/dev/null || echo ziti-controller)"
  fi

  if [[ -z "$ZITI_CLUSTER_TRUST_DOMAIN" ]]; then
    ZITI_CLUSTER_TRUST_DOMAIN="$(awk -F. '{if (NF>=2) print $(NF-1)"."$NF; else print $0}' <<<"$ZITI_DNS")"
  fi
}

write_bootstrap_answers() {
  log "Writing OpenZiti v2 bootstrap answer file"
  log "Controller advertised address: ${ZITI_DNS}"
  log "Controller advertised port: ${ZITI_PORT}"
  log "Cluster node name: ${ZITI_CLUSTER_NODE_NAME}"
  log "Trust domain: ${ZITI_CLUSTER_TRUST_DOMAIN}"

  cat > "$BOOTSTRAP_ANSWERS" <<EOF_ANSWERS
ZITI_CTRL_ADVERTISED_ADDRESS='${ZITI_DNS}'
ZITI_CTRL_ADVERTISED_PORT='${ZITI_PORT}'
ZITI_USER='${ZITI_USER}'
ZITI_PWD='${ZITI_PWD}'
ZITI_CLUSTER_NODE_NAME='${ZITI_CLUSTER_NODE_NAME}'
ZITI_CLUSTER_TRUST_DOMAIN='${ZITI_CLUSTER_TRUST_DOMAIN}'
ZITI_CONSOLE='Y'
EOF_ANSWERS

  chmod 600 "$BOOTSTRAP_ANSWERS"
}

bootstrap_controller() {
  log "Bootstrapping OpenZiti v2 controller"

  [[ -x /opt/openziti/etc/controller/bootstrap.bash ]] || fail "Bootstrap script not found."

  /opt/openziti/etc/controller/bootstrap.bash "$BOOTSTRAP_ANSWERS"

  if [[ -f "$CONTROLLER_DIR/raft/ctrl-ha.db" ]]; then
    log "OpenZiti v2 RAFT database found: $CONTROLLER_DIR/raft/ctrl-ha.db"
  else
    systemctl status ziti-controller.service --no-pager -l || true
    journalctl -u ziti-controller.service -n 120 --no-pager || true
    fail "OpenZiti v2 database was not created at $CONTROLLER_DIR/raft/ctrl-ha.db."
  fi

  [[ -d "$CONTROLLER_DIR/pki" ]] || fail "PKI directory was not created at $CONTROLLER_DIR/pki."
}

validate_controller() {
  log "Validating controller service"

  systemctl enable ziti-controller.service >/dev/null
  systemctl restart ziti-controller.service

  sleep 3

  systemctl is-active --quiet ziti-controller.service || {
    systemctl status ziti-controller.service --no-pager -l || true
    journalctl -u ziti-controller.service -n 120 --no-pager || true
    fail "ziti-controller.service is not active."
  }

  ss -tlnp | grep -E ":${ZITI_PORT}\b" || fail "Controller is not listening on port ${ZITI_PORT}."

  log "Validating ZAC local response"
  curl -kfsS "https://127.0.0.1:${ZITI_PORT}/zac/" >/dev/null || fail "Local ZAC test failed."
}

print_summary() {
  cat <<EOF_SUMMARY

============================================================
OpenZiti v2 Controller + ZAC installation completed.
============================================================

Controller/ZAC direct URL:
  https://${ZITI_DNS}:${ZITI_PORT}/zac/

Admin username:
  ${ZITI_USER}

Installed OpenZiti version:
  ${OPENZITI_VERSION}

Installed ZAC/openziti-console version:
  ${CONSOLE_VERSION}

Important checks:
  sudo systemctl status ziti-controller.service --no-pager -l
  sudo journalctl -u ziti-controller.service -n 80 --no-pager
  curl -k https://127.0.0.1:${ZITI_PORT}/zac/ | head
  ziti edge login https://${ZITI_DNS}:${ZITI_PORT} -u ${ZITI_USER}

Recommended next step:
  Run the separate NGINX + Let's Encrypt + ZAC assets fix script.

============================================================

EOF_SUMMARY
}

main() {
  require_root
  require_apt
  collect_inputs
  validate_dns
  prepare_system
  add_openziti_repo
  resolve_versions
  check_existing_install
  install_openziti_packages
  derive_bootstrap_defaults
  write_bootstrap_answers
  bootstrap_controller
  validate_controller
  print_summary
}

main "$@"
