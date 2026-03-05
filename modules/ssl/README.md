# ssl — HTTPS via Traefik + Let's Encrypt

> **Experimental:** This module is not yet fully implemented. It may be incomplete or unstable. Use at your own risk.

Adds a Traefik reverse proxy with automatic TLS certificates from Let's Encrypt. All services switch from port-based access to subdomain-based HTTPS.

## Enable

```bash
./module.sh enable ssl
```

Interactive setup asks for:

1. **Base domain** (e.g. `ai.example.com`)
2. **DNS provider** — INWX, Cloudflare, or AWS Route53
3. **DNS credentials** — API key/password for your provider
4. **Email** — for Let's Encrypt notifications

## Result

All services become accessible via HTTPS subdomains:

| Service | URL |
|---------|-----|
| Homepage | `https://ai.example.com` |
| Open WebUI | `https://webui.ai.example.com` |
| Traefik Dashboard | `https://traefik.ai.example.com` |

Ports 80 and 443 are handled by Traefik. Individual service ports are no longer exposed.

## DNS Setup

Point a wildcard DNS record to your server:

```
*.ai.example.com → <your-server-IP>
ai.example.com   → <your-server-IP>
```

## Staging vs Production

ancroo-stack defaults to Let's Encrypt **Production** certificates.

The setup optionally offers a staging test before issuing the real certificate. This verifies that DNS credentials and domain configuration are correct without consuming production rate limits.

**Why production by default?** DNS-01 uses no open ports and a wildcard certificate counts as a single issuance — production rate limits are not a concern for normal use.

**Why not staging permanently?** Staging certificates are signed by a fake CA that is not in any trust store. Beyond browser warnings, this breaks:

- **Service-to-service HTTPS** — Containers (e.g. n8n, BookStack) fail TLS verification when calling other services via their domain
- **Webhooks** — Inbound/outbound webhooks reject the untrusted certificate
- **Browser extensions** — Certificate errors on every API call

Staging is only useful for debugging the ACME/DNS-01 flow itself.

## Supported DNS Providers

| Provider | Variable | Credentials |
|----------|----------|-------------|
| INWX | `DNS_PROVIDER="dns_inwx"` | `INWX_USERNAME`, `INWX_PASSWORD` |
| Cloudflare | `DNS_PROVIDER="dns_cf"` | `CF_EMAIL`, `CF_KEY` |
| AWS Route53 | `DNS_PROVIDER="dns_aws"` | `AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY` |

## Certificate Renewal

Certificates are valid for 90 days. To manually renew:

```bash
bash modules/ssl/post-enable.sh
```

## Disable

```bash
./module.sh disable ssl
```

All services switch back to port-based HTTP access automatically.

## Services

| Container | Purpose |
|-----------|---------|
| traefik | Reverse proxy, TLS termination |
| acme | Certificate management (acme.sh) |
