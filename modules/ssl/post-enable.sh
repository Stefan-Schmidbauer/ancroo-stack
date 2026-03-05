#!/bin/bash
# SSL Module — Post-Enable
# Runs AFTER service start.
# Creates tls.yml, issues certificate via acme.sh.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

source "$PROJECT_ROOT/tools/install/lib/common.sh"

# Load .env
safe_source_env "$PROJECT_ROOT/.env"

# ─── 1. Create tls.yml for Traefik file provider ──────────
print_step "Creating TLS configuration"

mkdir -p "$PROJECT_ROOT/data/traefik/certs"

cat > "$PROJECT_ROOT/data/traefik/certs/tls.yml" << EOF
tls:
  certificates:
    - certFile: /certs/${BASE_DOMAIN}.crt
      keyFile: /certs/${BASE_DOMAIN}.key
  stores:
    default:
      defaultCertificate:
        certFile: /certs/${BASE_DOMAIN}.crt
        keyFile: /certs/${BASE_DOMAIN}.key
EOF

print_success "tls.yml created"

# ─── 2. Wait for acme container ───────────────────────────
print_step "Waiting for acme.sh container"

for i in $(seq 1 30); do
    if docker ps --format '{{.Names}}' | grep -q '^acme$'; then
        print_success "acme.sh container is running"
        break
    fi
    sleep 1
    if [[ $i -eq 30 ]]; then
        print_error "acme.sh container failed to start"
        print_info "Logs: docker compose logs acme"
        exit 1
    fi
done

# ─── 3. Issue certificate ─────────────────────────────────
print_step "Issuing certificate (DNS-01 challenge)"
print_info "Wildcard certificate for *.${BASE_DOMAIN}"
print_warning "This takes 2-3 minutes (DNS propagation)..."

# Provider-specific credentials via env file (avoids exposing secrets in ps output)
ACME_DNS_FLAG=""
DNS_ENV_FILE=$(mktemp "${PROJECT_ROOT}/data/traefik/.dns-env.XXXXXX")
chmod 600 "$DNS_ENV_FILE"
cleanup_dns_env() { rm -f "$DNS_ENV_FILE"; }
trap cleanup_dns_env EXIT

case "$DNS_PROVIDER" in
    dns_inwx)
        echo "INWX_User=${INWX_USERNAME}" >> "$DNS_ENV_FILE"
        echo "INWX_Password=${INWX_PASSWORD}" >> "$DNS_ENV_FILE"
        if [[ -n "${INWX_SHARED_SECRET:-}" ]]; then
            echo "INWX_Shared_Secret=${INWX_SHARED_SECRET}" >> "$DNS_ENV_FILE"
        fi
        ACME_DNS_FLAG="dns_inwx"
        ;;
    dns_cf)
        echo "CF_Email=${CF_EMAIL}" >> "$DNS_ENV_FILE"
        echo "CF_Key=${CF_KEY}" >> "$DNS_ENV_FILE"
        ACME_DNS_FLAG="dns_cf"
        ;;
    dns_aws)
        echo "AWS_ACCESS_KEY_ID=${AWS_ACCESS_KEY_ID}" >> "$DNS_ENV_FILE"
        echo "AWS_SECRET_ACCESS_KEY=${AWS_SECRET_ACCESS_KEY}" >> "$DNS_ENV_FILE"
        ACME_DNS_FLAG="dns_aws"
        ;;
    *)
        print_error "Unknown DNS provider: $DNS_PROVIDER"
        exit 1
        ;;
esac

# Copy env file into acme container (credentials stay off the process table)
docker cp "$DNS_ENV_FILE" acme:/tmp/dns-env

# Helper: run acme.sh with DNS credentials loaded inside the container
acme_exec() {
    docker exec acme sh -c '. /tmp/dns-env && acme.sh "$@"' -- "$@"
}

# ─── 3a. Optional staging test ────────────────────────────
if [[ "${ACME_STAGING_TEST:-false}" == "true" ]]; then
    print_step "Staging test (validating DNS credentials)"
    print_info "Testing DNS-01 challenge with staging server..."

    if acme_exec --issue \
        --dns "$ACME_DNS_FLAG" \
        -d "$BASE_DOMAIN" \
        -d "*.${BASE_DOMAIN}" \
        --server letsencrypt_test \
        --keylength ec-256; then
        print_success "Staging test passed — DNS credentials are valid"

        # Remove staging certificate
        docker exec acme acme.sh --remove -d "$BASE_DOMAIN" --ecc 2>/dev/null || true
        print_info "Staging certificate removed, issuing production certificate..."
    else
        print_error "Staging test failed!"
        print_info "Possible causes:"
        print_info "  - DNS not configured (*.${BASE_DOMAIN} -> server IP)"
        print_info "  - DNS provider credentials invalid"
        print_info ""
        print_info "Retry later:"
        print_info "  bash modules/ssl/post-enable.sh"
        echo ""
        exit 0
    fi
fi

# ─── 3b. Issue production certificate ─────────────────────
# Check if certificate already exists
if docker exec acme acme.sh --list 2>/dev/null | grep -q "$BASE_DOMAIN"; then
    print_warning "Certificate for $BASE_DOMAIN already exists"
    # Skip to install
else
    if acme_exec --issue \
        --dns "$ACME_DNS_FLAG" \
        -d "$BASE_DOMAIN" \
        -d "*.${BASE_DOMAIN}" \
        --server "$ACME_SERVER" \
        --keylength ec-256; then
        print_success "Production certificate issued"
    else
        print_error "Certificate issuance failed!"
        print_info "Possible causes:"
        print_info "  - DNS not configured (*.${BASE_DOMAIN} -> server IP)"
        print_info "  - DNS provider credentials invalid"
        print_info "  - Rate limit reached"
        print_info ""
        print_info "Retry later:"
        print_info "  bash modules/ssl/post-enable.sh"
        echo ""
        # No exit 1 — module stays active, certificate can be retried
        exit 0
    fi
fi

# Clean up credentials from container
docker exec acme rm -f /tmp/dns-env 2>/dev/null || true

# ─── 4. Install certificate ───────────────────────────────
print_step "Installing certificate"

if docker exec acme acme.sh --install-cert \
    -d "$BASE_DOMAIN" \
    --key-file "/certs/${BASE_DOMAIN}.key" \
    --fullchain-file "/certs/${BASE_DOMAIN}.crt" \
    --reloadcmd "chmod 644 /certs/${BASE_DOMAIN}.key /certs/${BASE_DOMAIN}.crt" \
    --ecc; then
    print_success "Certificate installed"
else
    print_error "Certificate installation failed"
    exit 1
fi

# ─── 5. Offer to remove DNS credentials from .env ────────
# acme.sh stores credentials internally after successful issue,
# so automatic renewals work without the .env values.
echo ""
if confirm "Remove DNS provider credentials from .env? (acme.sh handles renewals automatically)" "y"; then
    case "$DNS_PROVIDER" in
        dns_inwx)
            remove_env_var "INWX_USERNAME"
            remove_env_var "INWX_PASSWORD"
            remove_env_var "INWX_SHARED_SECRET"
            ;;
        dns_cf)
            remove_env_var "CF_EMAIL"
            remove_env_var "CF_KEY"
            ;;
        dns_aws)
            remove_env_var "AWS_ACCESS_KEY_ID"
            remove_env_var "AWS_SECRET_ACCESS_KEY"
            ;;
    esac
    print_success "DNS credentials removed from .env"
    print_info "To re-issue manually later, run: ./module.sh setup ssl"
else
    print_info "DNS credentials kept in .env"
fi

# ─── 6. Restart Traefik ──────────────────────────────────
print_step "Restarting Traefik"
cd "$PROJECT_ROOT"
docker compose restart traefik
sleep 3
print_success "Traefik restarted"

# ─── 7. Access URLs ───────────────────────────────────────
echo ""
echo -e "  ${BOLD}SSL enabled!${NC}"
echo ""
echo "  Access:"
echo -e "    Homepage:    ${CYAN}https://${BASE_DOMAIN}${NC}"
echo -e "    Open WebUI:  ${CYAN}https://webui.${BASE_DOMAIN}${NC}"
echo -e "    Ollama API:  ${CYAN}https://ollama.${BASE_DOMAIN}${NC}"
echo -e "    Traefik:     ${CYAN}https://traefik.${BASE_DOMAIN}${NC}"
echo ""

# ─── 8. DNS hint ──────────────────────────────────────────
echo "  DNS records (if not configured yet):"
echo "    ${BASE_DOMAIN}    -> server IP"
echo "    *.${BASE_DOMAIN}  -> server IP"
echo ""
