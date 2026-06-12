#!/usr/bin/env bash
set -Eeuo pipefail
exec > >(tee -a /var/log/ziti-v3-router-bootstrap.log) 2>&1
CTRL_URL="${1:?missing controller url}"
CTRL_USER="${2:-admin}"
CTRL_PWD_B64="${3:?missing controller password b64}"
ROUTER_NAME="${4:?missing router name}"
ROUTER_ADVERTISED_HOST="${5:?missing router advertised host}"
ROUTER_ROLE="${6:-edge-fabric}"
RUN_APT_UPGRADE="${7:-true}"
REPO_RAW_BASE_URL="${8:-https://raw.githubusercontent.com/mohamedelrehan/Ziti-V3/main}"
CTRL_PWD="$(printf "%s" "$CTRL_PWD_B64" | base64 -d)"
STATUS="success"
log(){ printf '\n[INFO] %s\n' "$*"; }
warn(){ printf '\n[WARN] %s\n' "$*" >&2; STATUS="warning"; }
finish(){ mkdir -p /opt/ziti-v3-router; cat >/opt/ziti-v3-router/router-status.txt <<EOF
status=${STATUS}
router_name=${ROUTER_NAME}
router_role=${ROUTER_ROLE}
controller_url=${CTRL_URL}
advertised_host=${ROUTER_ADVERTISED_HOST}
finished_at=$(date -Is)
log=/var/log/ziti-v3-router-bootstrap.log
health_check=/opt/ziti-v3-router/check-router.sh
EOF
log "Returning success to Azure Custom Script Extension. Router bootstrap status=${STATUS}"; exit 0; }
trap finish EXIT
write_health(){ mkdir -p /opt/ziti-v3-router; cat >/opt/ziti-v3-router/check-router.sh <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
echo "=== Router status ==="; cat /opt/ziti-v3-router/router-status.txt 2>/dev/null || true
echo; echo "=== ziti version ==="; ziti version || true
echo; echo "=== ziti-router service ==="; sudo systemctl status ziti-router --no-pager -l || true
echo; echo "=== Listening ports ==="; sudo ss -tulpn | egrep '3022|10080|1280' || true
echo; echo "=== Logs ==="; sudo journalctl -u ziti-router -n 80 --no-pager || true
EOF
chmod +x /opt/ziti-v3-router/check-router.sh; }
install_pkgs(){ log "Installing OpenZiti packages"; apt-get update; if [[ "$RUN_APT_UPGRADE" == "true" ]]; then DEBIAN_FRONTEND=noninteractive apt-get upgrade -y; fi; DEBIAN_FRONTEND=noninteractive apt-get install -y curl gpg ca-certificates jq dnsutils iproute2; curl -sSLf https://get.openziti.io/tun/package-repos.gpg | gpg --dearmor --yes --output /usr/share/keyrings/openziti.gpg; chmod a+r /usr/share/keyrings/openziti.gpg; echo 'deb [signed-by=/usr/share/keyrings/openziti.gpg] https://packages.openziti.org/zitipax-openziti-deb-stable debian main' >/etc/apt/sources.list.d/openziti-release.list; apt-get update; DEBIAN_FRONTEND=noninteractive apt-get install -y openziti openziti-router; }
wait_controller(){ log "Waiting for controller ${CTRL_URL}"; for i in $(seq 1 60); do if curl -kfsS "${CTRL_URL}/zac/" >/dev/null; then log "Controller reachable"; return 0; fi; sleep 20; done; warn "Controller not reachable after wait"; return 1; }
create_jwt(){ local jwt="/opt/ziti-v3-router/${ROUTER_NAME}.jwt"; mkdir -p /opt/ziti-v3-router; log "Login to controller"; ziti edge login "$CTRL_URL" -u "$CTRL_USER" -p "$CTRL_PWD" -y || { warn "ziti edge login failed"; return 1; }; log "Create edge-router JWT"; if ziti edge create edge-router "$ROUTER_NAME" -o "$jwt" -t; then :; elif ziti edge create edge-router "$ROUTER_NAME" --jwt-output-file "$jwt" --tunneler-enabled; then :; elif ziti edge create edge-router "$ROUTER_NAME" -o "$jwt"; then :; else warn "create edge-router failed"; return 1; fi; [[ -s "$jwt" ]] || { warn "JWT file missing/empty"; return 1; }; }
enroll(){ local jwt="/opt/ziti-v3-router/${ROUTER_NAME}.jwt"; log "Enroll router"; if ziti router enroll "$jwt"; then :; elif ziti router enroll --jwt "$jwt"; then :; else warn "ziti router enroll failed"; return 1; fi; }
start_router(){ log "Start router"; systemctl daemon-reload || true; systemctl enable ziti-router || true; systemctl restart ziti-router || true; sleep 5; systemctl is-active --quiet ziti-router || warn "ziti-router not active"; }
main(){ log "Starting router bootstrap $(date -Is)"; log "Router: ${ROUTER_NAME}, role=${ROUTER_ROLE}, advertised=${ROUTER_ADVERTISED_HOST}"; write_health; install_pkgs; wait_controller || return 0; create_jwt || return 0; enroll || return 0; cat >/opt/ziti-v3-router/router-profile.env <<EOF
ROUTER_NAME=${ROUTER_NAME}
ROUTER_ROLE=${ROUTER_ROLE}
ROUTER_ADVERTISED_HOST=${ROUTER_ADVERTISED_HOST}
CTRL_URL=${CTRL_URL}
EOF
start_router; /opt/ziti-v3-router/check-router.sh || true; }
main "$@"
