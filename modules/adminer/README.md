# adminer — Database Management UI

Web-based database management tool for PostgreSQL. Useful for inspecting databases created by modules.

## Enable

```bash
./module.sh enable adminer
```

## Access

| Mode | URL |
|------|-----|
| Base | `http://<IP>:8081` |
| SSL | `https://adminer.<BASE_DOMAIN>` |

## Login

Use the PostgreSQL credentials from `.env`:

| Field | Value |
|-------|-------|
| System | PostgreSQL |
| Server | `postgres` |
| Username | value of `POSTGRES_USER` |
| Password | value of `POSTGRES_PASSWORD` |
| Database | `ancroo` (or any module database) |

Module databases: `ancroo` (base), `ancroo_n8n`, `ancroo_ancroo`, `ancroo_bookstack`, `ancroo_keycloak` (when SSO enabled).

## Disable

```bash
./module.sh disable adminer
```
