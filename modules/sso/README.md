# sso — Single Sign-On

> **Experimental:** This module is not yet fully implemented. It may be incomplete or unstable. Use at your own risk.

Adds a centralized identity provider (Keycloak) so all services share the same login.

## Architecture

| Service | Purpose |
|---------|---------|
| **keycloak** | Identity Provider — User management, OAuth2/OIDC, Admin Console |
| **oauth2-proxy** | Forward Auth — Traefik middleware for proxy-protected services |

## Dependencies

Requires the `ssl` module (auto-enabled).

## Enable

```bash
./module.sh enable sso
# Auto-enables: ssl
```

## Authentication Methods

| Method | Services | How |
|--------|----------|-----|
| **OAuth2/OIDC** | Open WebUI, Ancroo | Service redirects to Keycloak login |
| **Forward Auth (Proxy)** | n8n, Adminer, Speaches, Traefik | Traefik validates session before forwarding |

## User Management

```bash
./module.sh sso add-user user@example.com
./module.sh sso list-users
./module.sh sso reset-password user@example.com
./module.sh sso delete-user user@example.com
```

## Admin Console

After enabling, the Keycloak Admin Console is available at `https://auth.<BASE_DOMAIN>`.

## Disable

```bash
./module.sh disable sso
```
