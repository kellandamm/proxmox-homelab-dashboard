#!/usr/bin/env bash
# ============================================================
# Homelab Dashboard — single-command Proxmox LXC installer
# Run on the Proxmox HOST as root:
#   bash -c "$(curl -fsSL https://raw.githubusercontent.com/kellandamm/proxmox-homelab-dashboard/main/homelab-dashboard.sh)"
# ============================================================
# Alpine 3.21 · Nginx · 1 CPU · 128 MB · 1 GB · unprivileged

set -Eeuo pipefail

RED="\033[0;31m"; GRN="\033[0;32m"; CYN="\033[0;36m"; BLD="\033[1m"; RST="\033[0m"
info(){ echo -e "  ${CYN}i${RST}  $*"; }
ok(){   echo -e "  ${GRN}v${RST}  $*"; }
err(){  echo -e "  ${RED}X${RST}  $*"; exit 1; }
trap 'echo -e "\n${RED}Install failed at line $LINENO${RST}"' ERR

[[ $EUID -ne 0 ]] && err "Run as root on the Proxmox host."
for cmd in pct pvesh pveam pvesm; do
  command -v "$cmd" >/dev/null 2>&1 || err "$cmd not found"
done

CT_VER="3.21"; CT_CPU="1"; CT_RAM="128"; CT_DISK="1"; CT_BRIDGE="vmbr0"

CTID=$(pvesh get /cluster/nextid)
[[ -z "$CTID" ]] && err "Could not determine next CTID."
ok "Container ID: $CTID"

STORAGE=$(pvesm status 2>/dev/null | awk 'NR>1 && $1=="local-lvm"{print $1; exit}')
[[ -z "$STORAGE" ]] && STORAGE=$(pvesm status 2>/dev/null | awk 'NR>1 && $1=="local"{print $1; exit}')
[[ -z "$STORAGE" ]] && STORAGE=$(pvesm status 2>/dev/null | awk 'NR>1{print $1; exit}')
[[ -z "$STORAGE" ]] && err "No storage pool found."
ok "Storage: $STORAGE"

info "Updating template catalog..."
pveam update >/dev/null 2>&1 || true
TEMPLATE=$(pveam available 2>/dev/null | awk "/alpine-${CT_VER}-default/ && /amd64/{print \$2; exit}")
[[ -z "$TEMPLATE" ]] && TEMPLATE="alpine-${CT_VER}-default_${CT_VER}_amd64.tar.xz"
pveam download local "$TEMPLATE" >/dev/null 2>&1 || true
ok "Template: $TEMPLATE"

info "Creating LXC..."
pct create "$CTID" "local:vztmpl/$TEMPLATE" \
  --hostname homelab-dashboard --unprivileged 1 \
  --cores "$CT_CPU" --memory "$CT_RAM" --rootfs "$STORAGE:$CT_DISK" \
  --net0 "name=eth0,bridge=$CT_BRIDGE,ip=dhcp,ip6=auto" --onboot 1 >/dev/null
ok "Container created"

pct start "$CTID" >/dev/null; sleep 5
ok "Container started"

pct exec "$CTID" -- sh -lc "apk update >/dev/null && apk add --no-cache nginx >/dev/null"
ok "Nginx installed"

# Dashboard HTML embedded as base64
DASHBOARD_B64='FULL_B64_HERE'
pct exec "$CTID" -- sh -lc "mkdir -p /usr/share/nginx/html"
echo "$DASHBOARD_B64" | base64 -d | pct exec "$CTID" -- sh -lc "cat > /usr/share/nginx/html/index.html"
ok "Dashboard written"

pct exec "$CTID" -- sh -lc "printf 'server {\n  listen 80;\n  server_name _;\n  root /usr/share/nginx/html;\n  index index.html;\n  location / { try_files \$uri \$uri/ /index.html; }\n}\n' > /etc/nginx/http.d/default.conf"
pct exec "$CTID" -- sh -lc "rc-update add nginx default >/dev/null && rc-service nginx restart >/dev/null"
ok "Nginx configured and started"

IP=$(pct exec "$CTID" -- sh -lc "ip -4 addr show eth0 2>/dev/null | awk '/inet /{print \$2}' | cut -d/ -f1 | head -n1" 2>/dev/null || true)
[[ -z "$IP" ]] && IP="(run: pct exec $CTID -- ip a)"
echo
echo -e "  ${GRN}${BLD}Homelab Dashboard is ready!${RST}"
echo -e "  Container ID : ${BLD}$CTID${RST}"
echo -e "  Dashboard URL: ${BLD}http://$IP${RST}"
echo -e "  Open shell   : pct exec $CTID -- ash"
echo
