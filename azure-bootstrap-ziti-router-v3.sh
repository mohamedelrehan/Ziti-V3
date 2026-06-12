#!/usr/bin/env bash
set -Eeuo pipefail

exec > >(tee -a /var/log/ziti-v3-router-bootstrap.log) 2>&1

CTRL_URL="${1:?missing controller private url}"
CTRL_USER="${2:-admin}"
CTRL_PWD_B64="${3:?missing controller password b64}"
ROUTER_NAME="${4:?missing router name}"
ROUTER_ADVERTISED_HOST="${5:?missing router advertised host}"
ROUTER_ROLE="${6:-edge-fabric}"
RUN_APT_UPGRADE="${7:-true}"
REPO_RAW_BASE_URL="${8:-https://raw.githubusercontent.com/mohamedelrehan/Ziti-V3/main}"

CTRL_PWD="$(printf "%s" "$CTRL_PWD_B64" | base64 -d)"
STATUS="success"
ROUTER_TYPE="edge"
ROUTER_MODE="host"

log() { printf '\n[INFO] %s\n' "$*"; }
warn() { printf '\n[WARN] %s\n' "$*" >&2; }
mark_warn() { STATUS="warning"; warn "$*"; }

finish_for_azure() {
  mkdir -p /opt/ziti-v3-router
  cat > /opt/ziti-v3-router/router-status.txt <<EOF_STATUS
status=${STATUS}
router_name=${ROUTER_NAME}
router_role=${ROUTER_ROLE}
router_type=${ROUTER_TYPE}
router_mode=${ROUTER_MODE}
controller_private_url=${CTRL_URL}
advertised_host=${ROUTER_ADVERTISED_HOST}
finished_at=$(date -Is)
log=/var/log/ziti-v3-router-bootstrap.log
health_check=/opt/ziti-v3-router/check-router.sh
config=/var/lib/ziti-router/config.yml
EOF_STATUS
  log "Router bootstrap status: ${STATUS}"
  log "Returning success to Azure Custom Script Extension."
  exit 0
}
trap finish_for_azure EXIT

map_router_role() {
  case "${ROUTER_ROLE}" in
    edge-fabric|edge|private-edge)
      ROUTER_TYPE="edge"
      ROUTER_MODE="host"
      ;;
    fabric)
      ROUTER_TYPE="fabric"
      ROUTER_MODE="none"
      ;;
    *)
      warn "Unknown router role ${ROUTER_ROLE}; defaulting to edge."
      ROUTER_TYPE="edge"
      ROUTER_MODE="host"
      ;;
  esac
}

write_health_check() {
  mkdir -p /opt/ziti-v3-router
  cat > /opt/ziti-v3-router/check-router.sh <<EOF_CHECK
#!/usr/bin/env bash
set -Eeuo pipefail
echo "=== Router status file ==="
cat /opt/ziti-v3-router/router-status.txt 2>/dev/null || true
echo
echo "=== ziti version ==="
ziti version || true
echo
echo "=== Router config ==="
sudo ls -lah /var/lib/ziti-router/ || true
sudo test -s /var/lib/ziti-router/config.yml && echo "config.yml exists" || echo "config.yml missing"
echo
echo "=== ziti-router service ==="
sudo systemctl status ziti-router --no-pager -l || true
echo
echo "=== Listening ports ==="
sudo ss -tulpn | egrep '3022|10080|1280' || true
echo
echo "=== Controller private API check ==="
curl -kI "${CTRL_URL}/zac/" || true
echo
echo "=== Router logs ==="
sudo journalctl -u ziti-router -n 120 --no-pager || true
EOF_CHECK
  chmod +x /opt/ziti-v3-router/check-router.sh
}

install_openziti_packages() {
  log "Installing OpenZiti packages"
  apt-get update
  if [[ "${RUN_APT_UPGRADE}" == "true" ]]; then
    DEBIAN_FRONTEND=noninteractive apt-get upgrade -y
  fi
  DEBIAN_FRONTEND=noninteractive apt-get install -y curl gpg ca-certificates jq dnsutils iproute2
  curl -sSLf https://get.openziti.io/tun/package-repos.gpg | gpg --dearmor --yes --output /usr/share/keyrings/openziti.gpg
  chmod a+r /usr/share/keyrings/openziti.gpg
  echo "deb [signed-by=/usr/share/keyrings/openziti.gpg] https://packages.openziti.org/zitipax-openziti-deb-stable debian main" > /etc/apt/sources.list.d/openziti-release.list
  apt-get update
  DEBIAN_FRONTEND=noninteractive apt-get install -y openziti openziti-router
}

wait_for_controller() {
  log "Waiting for controller private API ${CTRL_URL}"
  for i in $(seq 1 60); do
    if curl -kfsS "${CTRL_URL}/zac/" >/dev/null; then
      log "Controller reachable from router over private VNET."
      return 0
    fi
    warn "Controller not reachable yet. Attempt ${i}/60"
    sleep 10
  done
  mark_warn "Controller not reachable over private VNET."
  return 1
}

controller_login() {
  log "Logging into controller: ${CTRL_URL}"
  ziti edge login "${CTRL_URL}" -u "${CTRL_USER}" -p "${CTRL_PWD}" -y
}

create_router_jwt() {
  local jwt_file="/opt/ziti-v3-router/${ROUTER_NAME}.jwt"
  mkdir -p /opt/ziti-v3-router
  log "Creating edge-router JWT on controller for ${ROUTER_NAME}"
  if ziti edge create edge-router "${ROUTER_NAME}" -o "${jwt_file}" -t; then
    log "JWT created with -t."
  elif ziti edge create edge-router "${ROUTER_NAME}" --jwt-output-file "${jwt_file}" --tunneler-enabled; then
    log "JWT created with long options."
  elif ziti edge create edge-router "${ROUTER_NAME}" -o "${jwt_file}"; then
    log "JWT created without tunneler flag."
  else
    mark_warn "Failed to create edge router JWT."
    return 1
  fi
  [[ -s "${jwt_file}" ]] || { mark_warn "JWT missing or empty."; return 1; }
  chmod 600 "${jwt_file}"
}

write_bootstrap_answers() {
  local jwt_file="/opt/ziti-v3-router/${ROUTER_NAME}.jwt"
  local answer_file="/opt/ziti-v3-router/${ROUTER_NAME}-bootstrap.env"
  local ctrl_host
  ctrl_host="$(printf "%s" "${CTRL_URL}" | sed -E 's#^https?://##; s#:.*$##')"

  log "Writing native bootstrap answer file ${answer_file}"
  cat > "${answer_file}" <<EOF_ANSWERS
ZITI_BOOTSTRAP=true
ZITI_BOOTSTRAP_CONFIG=true
ZITI_BOOTSTRAP_ENROLLMENT=true
ZITI_ROUTER_NAME=${ROUTER_NAME}
ZITI_ROUTER_TYPE=${ROUTER_TYPE}
ZITI_ROUTER_MODE=${ROUTER_MODE}
ZITI_ROUTER_ADVERTISED_ADDRESS=${ROUTER_ADVERTISED_HOST}
ZITI_ROUTER_PORT=3022
ZITI_CTRL_ADVERTISED_ADDRESS=${ctrl_host}
ZITI_CTRL_ADVERTISED_PORT=1280
ZITI_ENROLL_TOKEN=${jwt_file}
EOF_ANSWERS
  chmod 600 "${answer_file}"
}

run_native_bootstrap() {
  local answer_file="/opt/ziti-v3-router/${ROUTER_NAME}-bootstrap.env"
  log "Running native OpenZiti router bootstrap"
  mkdir -p /var/lib/ziti-router
  ZITI_BOOTSTRAP=true ZITI_BOOTSTRAP_CONFIG=force ZITI_BOOTSTRAP_ENROLLMENT=force VERBOSE=1 \
    /opt/openziti/etc/router/bootstrap.bash "${answer_file}"
  [[ -s /var/lib/ziti-router/config.yml ]] || { mark_warn "config.yml missing after bootstrap."; return 1; }
}

validate_router_service() {
  systemctl daemon-reload || true
  systemctl enable ziti-router || true
  systemctl restart ziti-router || true
  sleep 8
  if systemctl is-active --quiet ziti-router; then
    log "ziti-router service is active."
  else
    mark_warn "ziti-router service is not active."
    journalctl -u ziti-router -n 150 --no-pager || true
  fi
}

main() {
  log "Starting router bootstrap fixed at $(date -Is)"
  log "Router name: ${ROUTER_NAME}"
  log "Router role: ${ROUTER_ROLE}"
  log "Controller private URL: ${CTRL_URL}"
  log "Advertised host: ${ROUTER_ADVERTISED_HOST}"
  map_router_role
  write_health_check
  install_openziti_packages
  wait_for_controller || return 0
  controller_login || { mark_warn "Controller login failed."; return 0; }
  create_router_jwt || return 0
  write_bootstrap_answers
  run_native_bootstrap || return 0
  validate_router_service
  /opt/ziti-v3-router/check-router.sh || true
}

main "$@"
