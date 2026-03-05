# bookstack — Wiki / Knowledge Base

Team wiki and knowledge base with structured documentation (Books / Chapters / Pages), REST API, and full-text search.

## Enable

```bash
./module.sh enable bookstack
```

## Access

| Mode | URL |
|------|-----|
| Base | `http://<IP>:8875` |
| SSL | `https://bookstack.<BASE_DOMAIN>` |

## First Login

BookStack creates a default admin user on first start:

| Field | Value |
|-------|-------|
| E-Mail | `admin@admin.com` |
| Password | `password` |

**Change these credentials immediately after first login.**

## Authentication

BookStack supports built-in user/password login (default) and OIDC single sign-on.

When the SSO module is enabled, BookStack will integrate with Keycloak. Login via "Login with Keycloak" button.

Without SSO, BookStack uses its built-in authentication.

## Services

| Container | Purpose |
|-----------|---------|
| bookstack | Wiki application (MIT license) |
| bookstack-db | MariaDB database (module-internal) |

## API

BookStack exposes a full REST API for external integration (LLM, MCP, automation).

| Endpoint | Description |
|----------|-------------|
| `GET /api/pages` | List all pages |
| `GET /api/pages/{id}` | Get page content (HTML + Markdown) |
| `GET /api/search?query=...` | Full-text search across all content |
| `POST /api/pages` | Create new page |
| `PUT /api/pages/{id}` | Update page |

**Authentication:** API Token (generate in User Profile > Access & Security)

```bash
curl -H "Authorization: Token <TOKEN_ID>:<TOKEN_SECRET>" \
  http://localhost:8875/api/pages
```

API documentation is available at `/api/docs` in your BookStack instance.

## Disable

```bash
./module.sh disable bookstack
```
