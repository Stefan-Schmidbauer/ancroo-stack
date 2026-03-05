#!/bin/bash
# BookStack Module Setup - Generates secrets if not yet configured
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
ENV_FILE="$PROJECT_ROOT/.env"

source "$PROJECT_ROOT/tools/install/lib/common.sh" 2>/dev/null || {
    print_info() { echo "  -> $1"; }
    print_success() { echo "  OK: $1"; }
}

generate_password() {
    openssl rand -hex 32
}

generate_app_key() {
    # Laravel requires exactly 32 bytes, base64-encoded with "base64:" prefix
    # base64 output is .env-safe (A-Za-z0-9+/= only)
    echo "base64:$(openssl rand -base64 32)"
}

# Generate secrets only if they contain CHANGE_ME placeholder
update_if_placeholder() {
    local key="$1"
    local generator="$2"

    local current_value
    current_value=$(grep "^${key}=" "$ENV_FILE" | cut -d= -f2- | tr -d '"')

    if [[ "$current_value" == CHANGE_ME* ]] || [[ -z "$current_value" ]]; then
        local new_value
        new_value=$($generator)
        update_env_var "$key" "$new_value"
        print_info "${key} generated"
    fi
}

print_info "Generating BookStack secrets..."

update_if_placeholder "BOOKSTACK_APP_KEY" generate_app_key
update_if_placeholder "BOOKSTACK_DB_PASSWORD" generate_password
update_if_placeholder "BOOKSTACK_DB_ROOT_PASSWORD" generate_password

print_success "BookStack secrets configured"

# ─── Set APP_URL based on install mode ────────────────────
safe_source_env "$ENV_FILE"
if [[ "${INSTALL_MODE:-base}" == "ssl" ]] && [[ -n "${BOOKSTACK_DOMAIN:-}" ]]; then
    update_env_var "BOOKSTACK_APP_URL" "https://${BOOKSTACK_DOMAIN}"
    print_info "APP_URL set to https://${BOOKSTACK_DOMAIN}"
else
    update_env_var "BOOKSTACK_APP_URL" "http://localhost:${BOOKSTACK_PORT:-8875}"
    print_info "APP_URL set to http://localhost:${BOOKSTACK_PORT:-8875}"
fi

# ─── Configure admin user ─────────────────────────────────
echo ""
print_step "BookStack admin user"
echo ""

# Non-interactive: preset via env vars
if [[ -n "${BOOKSTACK_ADMIN_EMAIL:-}" ]]; then
    ADMIN_EMAIL="$BOOKSTACK_ADMIN_EMAIL"
    print_info "Admin email: $ADMIN_EMAIL (preset)"
else
    ADMIN_EMAIL=$(prompt_input "Admin email" "admin@admin.com")
fi

if [[ -n "${BOOKSTACK_ADMIN_PASSWORD:-}" ]]; then
    ADMIN_PASSWORD="$BOOKSTACK_ADMIN_PASSWORD"
    print_info "Admin password: set (preset)"
else
    while true; do
        ADMIN_PASSWORD=$(prompt_input "Admin password (min 8 chars)" "" "true")
        if [[ -z "$ADMIN_PASSWORD" ]]; then
            ADMIN_PASSWORD=$(openssl rand -base64 12)
            print_info "No password provided — generated: ${ADMIN_PASSWORD}"
            break
        elif [[ "${#ADMIN_PASSWORD}" -lt 8 ]]; then
            print_error "Password must be at least 8 characters"
        else
            break
        fi
    done
fi

update_env_var "BOOKSTACK_ADMIN_EMAIL" "$ADMIN_EMAIL"
update_env_var "BOOKSTACK_ADMIN_PASSWORD" "$ADMIN_PASSWORD"

echo ""
print_success "Admin: $ADMIN_EMAIL"
echo ""
echo "  For SSO: ./module.sh enable sso"
echo ""
