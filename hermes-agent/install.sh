#!/usr/bin/env bash
# =============================================================================
# Hermes Agent — Proxmox VE LXC Installer
# Repo   : https://github.com/kellandamm/Proxmox-Scripts
# Upstream: https://github.com/NousResearch/hermes-agent
# Run on the Proxmox HOST as root:
#   bash <(curl -fsSL https://raw.githubusercontent.com/kellandamm/Proxmox-Scripts/main/hermes-agent/install.sh)
# =============================================================================
set -Eeuo pipefail

# ── Colour helpers ────────────────────────────────────────────────────────────
RED="\033[0;31m"; GRN="\033[0;32m"; CYN="\033[0;36m"; YLW="\033[0;33m"; RST="\033[0m"
info(){ echo -e "  ${CYN}i${RST}  $*"; }
ok(){   echo -e "  ${GRN}+${RST}  $*"; }
warn(){ echo -e "  ${YLW}!${RST}  $*"; }
err(){  echo -e "  ${RED}x${RST}  $*"; exit 1; }
trap 'echo -e "\n${RED}Install failed near line $LINENO — check output above.${RST}"' ERR

# ── Pre-flight ────────────────────────────────────────────────────────────────
[[ $EUID -ne 0 ]] && err "Run as root on the Proxmox host."
for cmd in pct pvesh pveam pvesm; do
  command -v "$cmd" >/dev/null 2>&1 || err "'$cmd' not found — is this a Proxmox VE host?"
done

# ── Tuneable defaults (override via env before running) ───────────────────────
: "${CTID:=$(pvesh get /cluster/nextid)}"
: "${HOSTNAME:=hermes-agent}"
: "${CORES:=2}"
: "${MEMORY:=2048}"          # MB — 2 GB minimum; uv + Node.js + Playwright need headroom
: "${DISK:=8}"               # GB rootfs
: "${BRIDGE:=vmbr0}"
: "${HERMES_PORT:=9119}"     # WebUI / dashboard port
: "${UNPRIVILEGED:=1}"

# ── Resolve storage ───────────────────────────────────────────────────────────
STORAGE=$(pvesm status | awk 'NR>1 && $1=="local-lvm"{print $1; exit}')
[[ -z "$STORAGE" ]] && STORAGE=$(pvesm status | awk 'NR>1 && $1=="local"{print $1; exit}')
[[ -z "$STORAGE" ]] && STORAGE=$(pvesm status | awk 'NR>1 {print $1; exit}')
[[ -z "$STORAGE" ]] && err "No usable storage pool found."

ok "CTID    : $CTID"
ok "Storage : $STORAGE"
ok "Hostname: $HOSTNAME"
ok "Resources: ${CORES} vCPU · ${MEMORY} MB RAM · ${DISK} GB disk"
ok "Dashboard port: $HERMES_PORT"

# ── Fetch latest Ubuntu 22.04 LXC template ────────────────────────────────────
info "Updating template catalog…"
pveam update >/dev/null 2>&1 || true

TEMPLATE=$(pveam available 2>/dev/null \
  | awk '/^system[[:space:]]+ubuntu-22\.04-standard/ && /amd64/ {print $2}' \
  | sort -V | tail -n1)

if [[ -z "$TEMPLATE" ]]; then
  warn "Ubuntu 22.04 not found; falling back to Ubuntu 24.04…"
  TEMPLATE=$(pveam available 2>/dev/null \
    | awk '/^system[[:space:]]+ubuntu-24\.04-standard/ && /amd64/ {print $2}' \
    | sort -V | tail -n1)
fi
[[ -z "$TEMPLATE" ]] && err "No Ubuntu template found in pveam available."
ok "Template: $TEMPLATE"

info "Downloading template if needed…"
pveam download local "$TEMPLATE" >/dev/null 2>&1 || true
TEMPLATE_VOL=$(pveam list local 2>/dev/null | awk -v t="$TEMPLATE" '$1~t{print $1;exit}')
[[ -z "$TEMPLATE_VOL" ]] && err "Template not found on local storage after download."
ok "Template volume: $TEMPLATE_VOL"

# ── Create LXC container ──────────────────────────────────────────────────────
info "Creating LXC container CT${CTID}…"
pct create "$CTID" "$TEMPLATE_VOL" \
  --hostname "$HOSTNAME" \
  --unprivileged "$UNPRIVILEGED" \
  --cores "$CORES" \
  --memory "$MEMORY" \
  --swap 512 \
  --rootfs "${STORAGE}:${DISK}" \
  --net0 name=eth0,bridge=${BRIDGE},ip=dhcp,ip6=auto \
  --features nesting=1 \
  --onboot 1 \
  --start 0 \
  >/dev/null
ok "Container created."

# ── Nesting is required for Docker-in-LXC (Hermes uses Docker sessions) ───────
pct set "$CTID" --features nesting=1 >/dev/null 2>&1 || true

info "Starting container…"
pct start "$CTID" >/dev/null
sleep 8   # wait for network + init

# ── Helper: run commands inside the container ─────────────────────────────────
run(){ pct exec "$CTID" -- bash -c "$1"; }

# ── System bootstrap ──────────────────────────────────────────────────────────
info "Bootstrapping system packages…"
run "export DEBIAN_FRONTEND=noninteractive
  apt-get update -qq
  apt-get install -y -qq --no-install-recommends \
    ca-certificates curl git gnupg lsb-release wget \
    build-essential libssl-dev libffi-dev >/dev/null 2>&1"
ok "System packages installed."

# ── Docker Engine ─────────────────────────────────────────────────────────────
info "Installing Docker Engine…"
run "install -m 0755 -d /etc/apt/keyrings
  curl -fsSL https://download.docker.com/linux/ubuntu/gpg \
    | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
  chmod a+r /etc/apt/keyrings/docker.gpg
  echo \"deb [arch=\$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] \
    https://download.docker.com/linux/ubuntu \$(. /etc/os-release && echo \$VERSION_CODENAME) stable\" \
    > /etc/apt/sources.list.d/docker.list
  apt-get update -qq
  apt-get install -y -qq docker-ce docker-ce-cli containerd.io docker-compose-plugin >/dev/null 2>&1
  systemctl enable --now docker >/dev/null 2>&1"
ok "Docker installed."

# ── Hermes Agent directories ───────────────────────────────────────────────────
info "Preparing Hermes directories…"
run "mkdir -p /opt/hermes-agent /home/hermes/.hermes/skills"

# ── docker-compose.yml ────────────────────────────────────────────────────────
info "Writing docker-compose.yml…"
pct exec "$CTID" -- bash -c "cat > /opt/hermes-agent/docker-compose.yml" << 'COMPOSE'
version: '3.8'

services:
  hermes-agent:
    image: nousresearch/hermes-agent:latest
    container_name: hermes-agent
    restart: unless-stopped
    ports:
      - "${HERMES_PORT:-9119}:9119"   # WebUI dashboard
    environment:
      - LLM_PROVIDER=${LLM_PROVIDER:-openai}
      - LLM_API_KEY=${LLM_API_KEY:-}
      - LLM_MODEL=${LLM_MODEL:-gpt-4o}
      - HERMES_HOME=/home/hermes/.hermes
      - PORT=9119
    volumes:
      - hermes_memory:/home/hermes/.hermes
      - hermes_skills:/home/hermes/.hermes/skills
    depends_on:
      redis:
        condition: service_healthy

  redis:
    image: redis:7-alpine
    container_name: hermes-redis
    restart: unless-stopped
    command: >
      redis-server
      --appendonly yes
      --appendfsync everysec
      --maxmemory 512mb
      --maxmemory-policy allkeys-lru
    volumes:
      - redis_data:/data
    healthcheck:
      test: ["CMD", "redis-cli", "ping"]
      interval: 10s
      timeout: 5s
      retries: 3

volumes:
  hermes_memory:
  hermes_skills:
  redis_data:
COMPOSE
ok "docker-compose.yml written."

# ── .env file (secrets — chmod 600) ───────────────────────────────────────────
info "Writing default .env file (edit before first run)…"
pct exec "$CTID" -- bash -c "cat > /opt/hermes-agent/.env && chmod 600 /opt/hermes-agent/.env" << 'DOTENV'
# ─────────────────────────────────────────────────────────────────────────────
# Hermes Agent — Environment Configuration
# Edit this file, then restart:  docker compose up -d
# ─────────────────────────────────────────────────────────────────────────────

# LLM Provider: openai | anthropic | openrouter | ollama | nous-portal | custom
LLM_PROVIDER=openai

# API key for your chosen provider
LLM_API_KEY=sk-YOUR_KEY_HERE

# Model name (examples per provider)
# openai     → gpt-4o
# anthropic  → claude-opus-4-5
# openrouter → openai/gpt-4o
# ollama     → llama3
LLM_MODEL=gpt-4o

# Dashboard port (mapped to host)
HERMES_PORT=9119

# Optional — Telegram gateway
# TELEGRAM_BOT_TOKEN=
# TELEGRAM_ALLOWED_USERS=

# Optional — Discord
# DISCORD_BOT_TOKEN=

# Optional — voice / TTS keys
# OPENAI_TTS_API_KEY=
DOTENV
ok ".env written."

# ── Systemd unit to auto-start Hermes on boot ─────────────────────────────────
info "Installing systemd service…"
pct exec "$CTID" -- bash -c "cat > /etc/systemd/system/hermes-agent.service" << 'UNIT'
[Unit]
Description=Hermes Agent (Docker Compose)
Requires=docker.service
After=docker.service network-online.target

[Service]
Type=oneshot
RemainAfterExit=yes
WorkingDirectory=/opt/hermes-agent
ExecStart=/usr/bin/docker compose --env-file /opt/hermes-agent/.env up -d --pull always
ExecStop=/usr/bin/docker compose down
TimeoutStartSec=300

[Install]
WantedBy=multi-user.target
UNIT
run "systemctl daemon-reload && systemctl enable hermes-agent.service >/dev/null 2>&1"
ok "systemd service enabled."

# ── Pull images now (so first boot is instant) ────────────────────────────────
info "Pre-pulling Docker images (this may take a few minutes)…"
run "cd /opt/hermes-agent && docker compose pull -q 2>&1 | tail -5" || warn "Image pull had warnings — will retry on first start."
ok "Images pulled."

# ── Start Hermes Agent ────────────────────────────────────────────────────────
info "Starting Hermes Agent…"
run "cd /opt/hermes-agent && docker compose --env-file /opt/hermes-agent/.env up -d" || true

# ── Resolve container IP ──────────────────────────────────────────────────────
IP=$(pct exec "$CTID" -- bash -c \
  "ip -4 addr show eth0 2>/dev/null | awk '/inet /{print \$2}' | cut -d/ -f1 | head -n1" 2>/dev/null || true)

# ── Done ──────────────────────────────────────────────────────────────────────
echo
echo -e "${GRN}══════════════════════════════════════════════════════════${RST}"
echo -e "${GRN}  Hermes Agent deployed successfully!${RST}"
echo -e "${GRN}══════════════════════════════════════════════════════════${RST}"
echo
echo -e "  CTID         : ${CYN}$CTID${RST}"
[[ -n "$IP" ]] && echo -e "  Host IP      : ${CYN}$IP${RST}"
echo -e "  Dashboard    : ${CYN}http://${IP:-<ct-ip>}:${HERMES_PORT}${RST}"
echo
echo -e "  ${YLW}Next steps:${RST}"
echo -e "  1. Edit the .env file inside the container:"
echo -e "     ${CYN}pct exec $CTID -- nano /opt/hermes-agent/.env${RST}"
echo -e "  2. Set your LLM_PROVIDER and LLM_API_KEY, then restart:"
echo -e "     ${CYN}pct exec $CTID -- bash -c 'cd /opt/hermes-agent && docker compose restart'${RST}"
echo -e "  3. Open the dashboard in your browser:"
echo -e "     ${CYN}http://${IP:-<ct-ip>}:${HERMES_PORT}${RST}"
echo
echo -e "  Shell access : ${CYN}pct exec $CTID -- bash${RST}"
echo -e "  View logs    : ${CYN}pct exec $CTID -- bash -c 'cd /opt/hermes-agent && docker compose logs -f'${RST}"
echo
