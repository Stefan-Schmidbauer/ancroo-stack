# n8n — Workflow Automation

Open-source workflow automation platform. Used by the Ancroo backend to execute AI workflows (grammar correction, transcription, etc.).

## Enable

```bash
./module.sh enable n8n
```

During setup, an owner account and API key are auto-provisioned. Credentials are stored in `.env`.

## Access

| Mode | URL |
|------|-----|
| Base | `http://<IP>:5678` |
| SSL | `https://n8n.<BASE_DOMAIN>` |

## First Login

The owner account is created automatically during module setup:

| Field | Source |
|-------|--------|
| Email | `N8N_ADMIN_EMAIL` in `.env` |
| Password | `N8N_ADMIN_PASSWORD` in `.env` |

## API Key

An API key (`ANCROO_N8N_API_KEY`) is auto-generated with workflow scopes for the Ancroo backend. To regenerate:

```bash
./module.sh setup n8n
```

## Database

PostgreSQL database `ancroo_n8n` (shared PostgreSQL instance).

## Disable

```bash
./module.sh disable n8n
```

> **Note:** The `ancroo` module depends on n8n. Disable ancroo first if active.
