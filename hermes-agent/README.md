# Hermes Agent — Proxmox VE LXC Installer

Deploys [NousResearch Hermes Agent](https://github.com/NousResearch/hermes-agent) into an **unprivileged Ubuntu 22.04 LXC** on Proxmox VE with:

- Docker Engine + Docker Compose
- Official `nousresearch/hermes-agent` image
- Redis 7 (persistent memory / skill store)
- Systemd service for auto-start on boot
- Pre-configured `.env` template for LLM provider keys

---

## Quick Install

Run the following **on your Proxmox host as root**:

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/kellandamm/Proxmox-Scripts/main/hermes-agent/install.sh)
```

The script takes ~3–5 minutes (mostly Docker image pulls).  
When it finishes it prints the dashboard URL.

---

## Default Container Spec

| Resource | Default | Override |
|---|---|---|
| CT ID | next available | `CTID=200` |
| Hostname | `hermes-agent` | `HOSTNAME=my-hermes` |
| vCPU | 2 | `CORES=4` |
| RAM | 2048 MB | `MEMORY=4096` |
| Disk | 8 GB | `DISK=20` |
| Bridge | `vmbr0` | `BRIDGE=vmbr1` |
| Dashboard port | `9119` | `HERMES_PORT=8080` |

Override any value as an env var before running:

```bash
CORES=4 MEMORY=4096 DISK=20 HERMES_PORT=8080 bash <(curl -fsSL ...)
```

---

## Post-Install Configuration

### 1. Set your LLM provider

```bash
pct exec <CTID> -- nano /opt/hermes-agent/.env
```

Edit `LLM_PROVIDER`, `LLM_API_KEY`, and `LLM_MODEL`.  
Supported providers:

| Provider | Example model |
|---|---|
| `openai` | `gpt-4o` |
| `anthropic` | `claude-opus-4-5` |
| `openrouter` | `openai/gpt-4o` |
| `ollama` | `llama3` (local) |
| `nous-portal` | Nous-hosted models |
| `custom` | Any OpenAI-compatible endpoint |

### 2. Restart the agent

```bash
pct exec <CTID> -- bash -c 'cd /opt/hermes-agent && docker compose restart'
```

### 3. Open the dashboard

```
http://<container-ip>:9119
```

The first-run setup wizard lets you select a provider, paste an API key, and connect messaging channels (Telegram, Discord, Slack, WhatsApp, Home Assistant, Signal).

---

## Useful Commands

```bash
# Shell into the container
pct exec <CTID> -- bash

# View live logs
pct exec <CTID> -- bash -c 'cd /opt/hermes-agent && docker compose logs -f'

# Stop Hermes
pct exec <CTID> -- bash -c 'cd /opt/hermes-agent && docker compose down'

# Update to the latest image
pct exec <CTID> -- bash -c 'cd /opt/hermes-agent && docker compose pull && docker compose up -d'

# Restart the systemd service (also starts on container boot)
pct exec <CTID> -- systemctl restart hermes-agent
```

---

## Architecture

```
Proxmox Host
└── CT <CTID>  Ubuntu 22.04 LXC (unprivileged, nesting=1)
    ├── Docker Engine
    │   ├── hermes-agent   nousresearch/hermes-agent:latest
    │   │   └── port 9119 → WebUI dashboard
    │   └── hermes-redis   redis:7-alpine
    │       └── persistent memory / skill store
    ├── /opt/hermes-agent/
    │   ├── docker-compose.yml
    │   └── .env           ← LLM keys (chmod 600)
    └── /home/hermes/.hermes/
        ├── (memory)       ← persistent volumes
        └── skills/        ← learned skill library
```

---

## Features of Hermes Agent

- **Self-improving** — builds a reusable skill library from experience (Honcho memory)
- **40+ built-in tools** — web search, browser automation, file ops, code execution
- **Multi-channel messaging** — Telegram, Discord, Slack, WhatsApp, Signal, Home Assistant
- **MCP integration** — connect any Model Context Protocol server
- **Multiple LLM backends** — OpenAI, Anthropic, OpenRouter, Ollama, custom endpoints
- **Terminal backends** — local, Docker, SSH, Daytona, Singularity, Modal

---

## Troubleshooting

**Container won't start** — check nesting is enabled:
```bash
pct config <CTID> | grep features
# should show: features: nesting=1
```

**Dashboard not reachable** — check the port mapping and container IP:
```bash
pct exec <CTID> -- ip addr show eth0
```

**Docker pull fails** — the container needs internet access via `vmbr0`. Verify your Proxmox bridge has a gateway.

**Agent not responding after key set** — always restart after editing `.env`:
```bash
pct exec <CTID> -- bash -c 'cd /opt/hermes-agent && docker compose restart'
```
