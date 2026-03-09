# Security Guide

## Credentials

All passwords are auto-generated during installation (32+ character random strings) and stored in `.env`.

- File permissions are set to `600` (owner-only) by `install.sh`
- `.env` is excluded from version control (`.gitignore`)
- Back up `.env` securely — it contains all service credentials

## Network Exposure

### Base Mode (default)

Services are exposed on individual ports **without TLS encryption**. Use base mode only in trusted networks (home lab, VPN).

### SSL Mode (experimental)

> **Note:** The SSL module is not yet fully implemented and may be incomplete or unstable.

The SSL module adds Traefik with TLS encryption. When enabled, only ports 80 and 443 are exposed with automatic HTTPS redirect. See [ssl module docs](../modules/ssl/README.md).

### Firewall

Restrict access to necessary ports:

```bash
# SSL mode (recommended)
sudo ufw allow 80/tcp
sudo ufw allow 443/tcp
sudo ufw enable

# Base mode — add ports for enabled modules as needed
sudo ufw allow 8080/tcp    # Open WebUI
sudo ufw allow 11434/tcp   # Ollama API
```

## First User

**Open WebUI:** The first account created gets admin privileges. Create your account immediately after installation to prevent unauthorized access.

## Password Rotation

### PostgreSQL

```bash
docker compose stop
docker compose start postgres
docker exec postgres psql -U ancroo -c "ALTER USER ancroo PASSWORD 'new-password';"

# Update POSTGRES_PASSWORD and all DATABASE_URL entries in .env
docker compose up -d
```

## Vulnerability Reporting

Report security issues privately via [GitHub Security Advisory](https://github.com/ancroo/ancroo-stack/security/advisories/new).

Response time: within 48 hours.
