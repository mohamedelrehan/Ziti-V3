#!/usr/bin/env bash
set -Eeuo pipefail
exec > >(tee -a /var/log/ziti-ha-test01-node-bootstrap.log) 2>&1

NODE_ROLE="${1:-unknown}"
NODE_NAME="${2:-unknown}"
RUN_APT_UPGRADE="${3:-true}"

log(){ printf '\n[INFO] %s\n' "$*"; }

log "Starting HA test01 node bootstrap"
log "Node role: ${NODE_ROLE}"
log "Node name: ${NODE_NAME}"

apt-get update
if [[ "${RUN_APT_UPGRADE}" == "true" ]]; then
  DEBIAN_FRONTEND=noninteractive apt-get upgrade -y
fi
DEBIAN_FRONTEND=noninteractive apt-get install -y curl ca-certificates jq dnsutils iproute2

mkdir -p /opt/ziti-ha-test01
cat > /opt/ziti-ha-test01/node-status.txt <<EOF
role=${NODE_ROLE}
name=${NODE_NAME}
finished_at=$(date -Is)
status=provisioned
log=/var/log/ziti-ha-test01-node-bootstrap.log
EOF

cat > /opt/ziti-ha-test01/check-node.sh <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
echo "=== Node status ==="
cat /opt/ziti-ha-test01/node-status.txt 2>/dev/null || true
echo
echo "=== Host ==="
hostname
hostname -I || true
echo
echo "=== Listening ports ==="
sudo ss -tulpn || true
EOF
chmod +x /opt/ziti-ha-test01/check-node.sh
log "HA test01 node bootstrap complete"
