# Operations Guide

## Installation

```bash
bash install.sh
```

The installer prompts for GPU mode (NVIDIA / AMD / CPU), generates `.env` with credentials, and starts the base stack (Ollama, Open WebUI, Homepage, PostgreSQL).

## Module Management

Extend the stack with optional modules. Dependencies are resolved automatically.

```bash
./module.sh list                        # Available modules
./module.sh status                      # Enabled modules and container health
./module.sh urls                        # Service URLs
./module.sh urls <IP>                   # /etc/hosts format for DNS entries
./module.sh ports                       # Modules with ports and status
./module.sh containers                  # Internal Docker network addresses (ai-network)
./module.sh info <name>                 # Module details
./module.sh setup <name>               # Re-run module setup
./module.sh enable <name>...            # Enable module(s) (starts containers)
./module.sh enable <name>... --dry-run  # Preview without changes
./module.sh disable <name>...           # Disable module(s) (stops containers)
```

Multiple modules can be enabled or disabled in a single command:

```bash
./module.sh enable bookstack n8n
./module.sh disable bookstack n8n
```

## Updates

### Container Images

The stack uses three image strategies:

| Strategy | Why | Examples | Update method |
|----------|-----|---------|---------------|
| **Pinned** (version tag) | Breaking-change protection for infrastructure | `traefik:v3.6`, `keycloak:26.1`, `oauth2-proxy:v7.14.2`, `acme.sh:3.1.1` | Change tag in compose YAML, then pull |
| **Floating** (`:latest`) | Always get newest features for AI/user-facing services | `ollama`, `open-webui`, `speaches`, `n8n` | `docker compose pull` |
| **Locally built** | Custom code, no registry image | `whisper-rocm`, `service-tools`, `ancroo-backend` | `docker compose build` |

Databases use major-version pins (`pgvector:pg16`, `mariadb:11`) to prevent schema-breaking upgrades while still receiving patch updates.

### Update Commands

```bash
# Update floating images from registries
docker compose pull

# Rebuild locally built images
docker compose build --no-cache

# Full update: pull + rebuild + restart
docker compose pull && docker compose up -d --build
```

Pinned images are not updated by `pull`. To upgrade a pinned image, edit the version tag in the module's `compose.yml` first.

### Updating Pinned Images

1. Check the release notes of the software for breaking changes
2. Update the image tag in `modules/<name>/compose.yml`
3. Run `docker compose pull <service> && docker compose up -d <service>`

## Service URLs

### Base Mode (default)

After installation, services are accessible via IP and port:

| Service | URL |
|---------|-----|
| Homepage Dashboard | `http://<IP>:80` |
| Open WebUI | `http://<IP>:8080` |
| Ollama API | `http://<IP>:11434` |

Optional modules (when enabled):

| Module | URL |
|--------|-----|
| n8n | `http://<IP>:5678` |
| BookStack | `http://<IP>:8875` |
| Adminer | `http://<IP>:8081` |
| Speaches | `http://<IP>:8100` |
| Whisper ROCm | `http://<IP>:8002` |
| Ancroo | `http://<IP>:8900` |
| Service Tools | `http://<IP>:8500` |

Your server IP is stored as `HOST_IP` in `.env` (auto-detected during installation).

### SSL Mode (experimental)

> **Note:** The SSL and SSO modules are not yet fully implemented and may be incomplete or unstable. The documentation below describes the intended behavior.

When SSL is enabled, all services switch to subdomain-based HTTPS access via Traefik. Ports 80 and 443 are handled by Traefik; individual service ports are no longer exposed.

| Service | URL | Variable |
|---------|-----|----------|
| Homepage Dashboard | `https://<domain>` | `HOMEPAGE_DOMAIN` |
| Open WebUI | `https://webui.<domain>` | `OPENWEBUI_DOMAIN` |
| Traefik Dashboard | `https://traefik.<domain>` | `TRAEFIK_DOMAIN` |
| Ollama API | `https://ollama.<domain>` | `OLLAMA_DOMAIN` |

Optional modules (when enabled):

| Module | URL | Variable |
|--------|-----|----------|
| n8n | `https://n8n.<domain>` | `N8N_DOMAIN` |
| BookStack | `https://bookstack.<domain>` | `BOOKSTACK_DOMAIN` |
| Adminer | `https://adminer.<domain>` | `ADMINER_DOMAIN` |
| Speaches | `https://speaches.<domain>` | `SPEACHES_DOMAIN` |
| Whisper ROCm | `https://whisper-rocm.<domain>` | `WHISPER_ROCM_DOMAIN` |
| Ancroo | `https://ancroo.<domain>` | `ANCROO_DOMAIN` |
| Service Tools | `https://service-tools.<domain>` | `SERVICE_TOOLS_DOMAIN` |
| Keycloak (SSO) | `https://auth.<domain>` | `KEYCLOAK_DOMAIN` |

`<domain>` is the `BASE_DOMAIN` set during `./module.sh enable ssl`. See [ssl module docs](../modules/ssl/README.md).

## First Login

**Open WebUI:** The first account created becomes admin. Create your account immediately after installation.

**n8n:** Owner account and API key are auto-provisioned during module setup. Credentials are stored in `.env` (`N8N_ADMIN_EMAIL`, `N8N_ADMIN_PASSWORD`).

**Adminer:** Use PostgreSQL credentials from `.env`:

- Server: `postgres`
- User: value of `POSTGRES_USER`
- Password: value of `POSTGRES_PASSWORD`
- Database: `ancroo`

## Status and Logs

```bash
# Active modules
./module.sh status

# Running containers
docker compose ps

# Container health
docker inspect <container> --format '{{.State.Health.Status}}'

# Service logs
docker compose logs <service>
docker compose logs -f <service>    # follow mode

# Module audit log (all enable/disable operations)
cat logs/module-actions.log
```

## Backups

### What to back up

| Path | Content | Size |
|------|---------|------|
| `.env` | All credentials and configuration | small |
| `data/postgresql/` | All databases | varies |
| `data/ollama/` | Downloaded LLM models | large (GBs) |
| `data/open-webui/` | User chats, uploaded documents | varies |

Module-specific data directories (e.g. `data/valkey/`) are also under `data/`.

### Backup

```bash
# Stop services for consistent backup
docker compose stop

# Create backup
tar -czf ancroo-backup-$(date +%Y%m%d).tar.gz data/ .env

# Restart
docker compose start
```

For encrypted backups:

```bash
tar -czf - data/ .env | gpg -c > ancroo-backup-$(date +%Y%m%d).tar.gz.gpg
```

### Restore

```bash
# Fresh install (creates base structure)
bash install.sh && docker compose stop

# Restore data
tar -xzf ancroo-backup-*.tar.gz

# Start
docker compose up -d
```

## Environment Variables

All configuration lives in `.env`, auto-generated by `install.sh` and managed by `module.sh`.

See [.env.example](../.env.example) for a full reference.

Key variables:

| Variable | Description |
|----------|-------------|
| `HOST_IP` | Server IP address (auto-detected) |
| `GPU_MODE` | `cpu`, `nvidia`, or `rocm` |
| `INSTALL_MODE` | `base` or `ssl` |
| `ENABLED_MODULES` | Space-separated list of active modules |
| `COMPOSE_FILE` | Docker Compose file chain (managed by module.sh) |
| `POSTGRES_PASSWORD` | Database password (auto-generated) |
| `WEBUI_SECRET_KEY` | Open WebUI session key (auto-generated) |

## Uninstallation

```bash
./uninstall.sh
```

Stops all containers and removes data directories. The script prompts individually for:

- **Ollama models** — kept by default (large downloads)
- **`.env` configuration** — can be kept for reinstallation
- **Docker images** — removed only on request
