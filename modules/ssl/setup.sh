#!/bin/bash
# SSL Module — Interactive Setup
# Called by module.sh before SSL services start.
# Asks for: Domain, DNS provider, credentials, email, ACME server.
# Non-interactive mode: export BASE_DOMAIN, DNS_PROVIDER, DNS credentials,
#   ACME_EMAIL, ACME_STAGING_TEST=true|false, SKIP_CONFIRM=1
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# Load common helpers (includes update_env_var)
source "$PROJECT_ROOT/tools/install/lib/common.sh"

# ─── 1. Domain ────────────────────────────────────────────
print_header "SSL Module — Setup"
echo "  HTTPS via Traefik + Let's Encrypt (DNS-01 Challenge)"
echo ""

if [[ -n "${BASE_DOMAIN:-}" ]]; then
    print_info "Domain: ${BASE_DOMAIN} (preset)"
else
    BASE_DOMAIN=$(prompt_input "Base domain (e.g. local.example.com)" "")
fi

if [[ -z "$BASE_DOMAIN" ]]; then
    print_error "Domain is required"
    exit 1
fi

# Basic domain validation
if [[ ! "$BASE_DOMAIN" =~ ^[a-zA-Z0-9]([a-zA-Z0-9.-]*[a-zA-Z0-9])?$ ]]; then
    print_error "Invalid domain format: $BASE_DOMAIN"
    exit 1
fi

# ─── 2. DNS Provider ─────────────────────────────────────
DNS_PROVIDER_LABEL=""
DNS_USER=""
DNS_KEY=""
INWX_SHARED_SECRET="${INWX_SHARED_SECRET:-}"

if [[ -n "${DNS_PROVIDER:-}" ]]; then
    # Non-interactive: provider pre-set, credentials read from env vars
    case "$DNS_PROVIDER" in
        dns_inwx)
            DNS_PROVIDER_LABEL="INWX"
            DNS_USER="${INWX_USERNAME:-}"
            DNS_KEY="${INWX_PASSWORD:-}"
            [[ -z "$DNS_USER" ]] && DNS_USER=$(prompt_input "INWX Username" "")
            [[ -z "$DNS_KEY" ]] && DNS_KEY=$(prompt_input "INWX Password" "" "true")
            if [[ -z "${INWX_SHARED_SECRET:-}" ]]; then
                echo ""
                if confirm "Two-factor authentication (2FA) enabled?" "n"; then
                    INWX_SHARED_SECRET=$(prompt_input "INWX Shared Secret (TOTP)" "" "true")
                fi
            fi
            print_success "DNS Provider: INWX"
            ;;
        dns_cf)
            DNS_PROVIDER_LABEL="Cloudflare"
            DNS_USER="${CF_EMAIL:-}"
            DNS_KEY="${CF_KEY:-}"
            [[ -z "$DNS_USER" ]] && DNS_USER=$(prompt_input "Cloudflare email" "")
            [[ -z "$DNS_KEY" ]] && DNS_KEY=$(prompt_input "Cloudflare API Key/Token" "" "true")
            print_success "DNS Provider: Cloudflare"
            ;;
        dns_aws)
            DNS_PROVIDER_LABEL="AWS Route53"
            DNS_USER="${AWS_ACCESS_KEY_ID:-}"
            DNS_KEY="${AWS_SECRET_ACCESS_KEY:-}"
            [[ -z "$DNS_USER" ]] && DNS_USER=$(prompt_input "AWS Access Key ID" "")
            [[ -z "$DNS_KEY" ]] && DNS_KEY=$(prompt_input "AWS Secret Access Key" "" "true")
            print_success "DNS Provider: AWS Route53"
            ;;
        *)
            print_error "Invalid DNS_PROVIDER '${DNS_PROVIDER}' — must be dns_inwx, dns_cf, or dns_aws"
            exit 1
            ;;
    esac
else
    # Interactive: show menu
    echo ""
    echo "  DNS provider for Let's Encrypt DNS-01 challenge:"
    echo "    1) INWX"
    echo "    2) Cloudflare"
    echo "    3) AWS Route53"
    echo ""
    echo -ne "  Selection [1-3]: "
    read -r dns_choice

    case "$dns_choice" in
        1)
            DNS_PROVIDER="dns_inwx"
            DNS_PROVIDER_LABEL="INWX"
            print_success "DNS Provider: INWX"
            echo ""
            DNS_USER=$(prompt_input "INWX Username" "")
            DNS_KEY=$(prompt_input "INWX Password" "" "true")

            echo ""
            if confirm "Two-factor authentication (2FA) enabled?" "n"; then
                INWX_SHARED_SECRET=$(prompt_input "INWX Shared Secret (TOTP)" "" "true")
            fi
            ;;
        2)
            DNS_PROVIDER="dns_cf"
            DNS_PROVIDER_LABEL="Cloudflare"
            print_success "DNS Provider: Cloudflare"
            echo ""
            DNS_USER=$(prompt_input "Cloudflare email" "")
            DNS_KEY=$(prompt_input "Cloudflare API Key/Token" "" "true")
            ;;
        3)
            DNS_PROVIDER="dns_aws"
            DNS_PROVIDER_LABEL="AWS Route53"
            print_success "DNS Provider: AWS Route53"
            echo ""
            DNS_USER=$(prompt_input "AWS Access Key ID" "")
            DNS_KEY=$(prompt_input "AWS Secret Access Key" "" "true")
            ;;
        *)
            print_error "Invalid selection"
            exit 1
            ;;
    esac
fi

# ─── 3. Email ────────────────────────────────────────────
echo ""
if [[ -z "${ACME_EMAIL:-}" ]]; then
    ACME_EMAIL=$(prompt_input "Email for Let's Encrypt" "admin@${BASE_DOMAIN}")
else
    print_info "Let's Encrypt email: ${ACME_EMAIL} (preset)"
fi

# ─── 4. ACME Server ──────────────────────────────────────
ACME_SERVER="letsencrypt"

if [[ -n "${ACME_STAGING_TEST:-}" ]]; then
    if [[ "$ACME_STAGING_TEST" == "true" ]]; then
        print_info "Staging test will run before issuing the production certificate (preset)"
    else
        print_success "ACME Server: Production (preset)"
    fi
else
    echo ""
    if confirm "Test with staging before production? (Validates DNS credentials without rate limits)" "n"; then
        ACME_STAGING_TEST="true"
        print_info "Staging test will run before issuing the production certificate"
    else
        ACME_STAGING_TEST="false"
        print_success "ACME Server: Production"
    fi
fi

# ─── 5. Confirmation ─────────────────────────────────────
echo ""
echo -e "  ${BOLD}Configuration:${NC}"
echo "    Domain:       ${BASE_DOMAIN}"
echo "    DNS Provider: ${DNS_PROVIDER_LABEL}"
echo "    DNS User:     ${DNS_USER}"
echo "    DNS Key:      ********"
echo "    Email:        ${ACME_EMAIL}"
echo "    ACME Server:  ${ACME_SERVER}$([ "$ACME_STAGING_TEST" = "true" ] && echo " (with staging pre-test)")"
echo ""

if [[ "${SKIP_CONFIRM:-0}" != "1" ]]; then
    if ! confirm "Apply configuration?"; then
        print_info "Setup cancelled"
        exit 1
    fi
else
    print_info "Applying configuration..."
fi

# ─── 6. Write to .env ────────────────────────────────────
print_step "Writing configuration"

# Domain variables
update_env_var "BASE_DOMAIN" "$BASE_DOMAIN"
update_env_var "TRAEFIK_DOMAIN" "traefik.${BASE_DOMAIN}"
update_env_var "OPENWEBUI_DOMAIN" "webui.${BASE_DOMAIN}"
update_env_var "HOMEPAGE_DOMAIN" "${BASE_DOMAIN}"
update_env_var "OLLAMA_DOMAIN" "ollama.${BASE_DOMAIN}"

# DNS provider credentials
update_env_var "DNS_PROVIDER" "$DNS_PROVIDER"
update_env_var "ACME_EMAIL" "$ACME_EMAIL"
update_env_var "ACME_SERVER" "$ACME_SERVER"
update_env_var "ACME_STAGING_TEST" "$ACME_STAGING_TEST"

case "$DNS_PROVIDER" in
    dns_inwx)
        update_env_var "INWX_USERNAME" "$DNS_USER"
        update_env_var "INWX_PASSWORD" "$DNS_KEY"
        if [[ -n "$INWX_SHARED_SECRET" ]]; then
            update_env_var "INWX_SHARED_SECRET" "$INWX_SHARED_SECRET"
        fi
        ;;
    dns_cf)
        update_env_var "CF_EMAIL" "$DNS_USER"
        update_env_var "CF_KEY" "$DNS_KEY"
        ;;
    dns_aws)
        update_env_var "AWS_ACCESS_KEY_ID" "$DNS_USER"
        update_env_var "AWS_SECRET_ACCESS_KEY" "$DNS_KEY"
        ;;
esac

print_success "SSL configuration written to .env"
echo ""
