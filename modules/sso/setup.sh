#!/bin/bash
# SSO Module — Interactive Setup
# Called by module.sh before Keycloak services start.
# Generates secrets, configures domains, and creates oauth2-proxy config.
# Non-interactive mode: export KEYCLOAK_ADMIN_EMAIL, CREATE_TEST_USER=yes|no,
#   CLAUDE_TEST_USER, SKIP_CONFIRM=1
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# Load common helpers (includes update_env_var)
source "$PROJECT_ROOT/tools/install/lib/common.sh"

# ─── 1. Check prerequisites ──────────────────────────────
print_header "SSO Module — Setup"
echo "  Single Sign-On via Keycloak (Identity Provider)"
echo "  Prerequisite: SSL module must be active."
echo ""

safe_source_env "$PROJECT_ROOT/.env"

if [[ -z "${BASE_DOMAIN:-}" ]]; then
    print_error "BASE_DOMAIN not set — enable the SSL module first!"
    exit 1
fi
print_success "BASE_DOMAIN: ${BASE_DOMAIN}"

# ─── 2. Admin email ──────────────────────────────────────
echo ""
if [[ -n "${KEYCLOAK_ADMIN_EMAIL:-}" ]]; then
    ADMIN_EMAIL="$KEYCLOAK_ADMIN_EMAIL"
    print_info "Admin email: $ADMIN_EMAIL (preset)"
else
    ADMIN_EMAIL=$(prompt_input "Keycloak admin email" "admin@${BASE_DOMAIN}")
fi

# ─── 3. Generate secrets ─────────────────────────────────
print_step "Generating secrets"

# Only regenerate KEYCLOAK_ADMIN_PASSWORD if not already set — prevents
# re-run collision where both admin and test user get the same password.
# Treat module.env placeholder values (changeme-*) as unset.
existing_kc_password=$(grep "^KEYCLOAK_ADMIN_PASSWORD=" "$PROJECT_ROOT/.env" 2>/dev/null \
    | head -1 | sed 's/^[^=]*=//;s/^"//;s/"$//' || true)
if [[ -z "${existing_kc_password:-}" ]] || [[ "$existing_kc_password" == changeme* ]]; then
    KEYCLOAK_ADMIN_PASSWORD=$(openssl rand -base64 24 | tr '+/=' 'Abc')
    print_success "KEYCLOAK_ADMIN_PASSWORD generated"
else
    KEYCLOAK_ADMIN_PASSWORD="$existing_kc_password"
    print_info "KEYCLOAK_ADMIN_PASSWORD: existing value retained"
fi

OAUTH2_PROXY_COOKIE_SECRET=$(openssl rand -base64 24 | tr -d '\n')
print_success "OAUTH2_PROXY_COOKIE_SECRET generated"

# ─── 4. Confirmation ─────────────────────────────────────
KEYCLOAK_DOMAIN="auth.${BASE_DOMAIN}"

echo ""
echo -e "  ${BOLD}Configuration:${NC}"
echo "    Keycloak Domain:  ${KEYCLOAK_DOMAIN}"
echo "    Admin Email:      ${ADMIN_EMAIL}"
echo -e "    Admin Password:   ${YELLOW}${KEYCLOAK_ADMIN_PASSWORD}${NC}"
echo "    Realm:            ancroo"
echo ""
print_info "Save this password — you need it to log into the Keycloak admin console."
print_info "It will be stored in .env (required by Docker Compose and SSO management scripts)."
echo ""

if [[ "${SKIP_CONFIRM:-0}" != "1" ]]; then
    if ! confirm "Apply configuration?"; then
        print_info "Setup cancelled"
        exit 1
    fi
else
    print_info "Applying configuration..."
fi

# ─── 5. Write to .env ────────────────────────────────────
print_step "Writing configuration"

update_env_var "KEYCLOAK_DOMAIN" "$KEYCLOAK_DOMAIN"
update_env_var "KEYCLOAK_DB" "ancroo_keycloak"
update_env_var "KEYCLOAK_ADMIN" "admin"
update_env_var "KEYCLOAK_ADMIN_PASSWORD" "$KEYCLOAK_ADMIN_PASSWORD"
update_env_var "KEYCLOAK_REALM" "ancroo"
update_env_var "KEYCLOAK_ADMIN_EMAIL" "$ADMIN_EMAIL"

# oauth2-proxy
update_env_var "OAUTH2_PROXY_CLIENT_ID" "ancroo-proxy"
update_env_var "OAUTH2_PROXY_COOKIE_SECRET" "$OAUTH2_PROXY_COOKIE_SECRET"

# OAuth URLs for Open WebUI
update_env_var "OAUTH_PROVIDER_NAME" "Keycloak"
update_env_var "OAUTH_AUTHORIZATION_URL" "https://${KEYCLOAK_DOMAIN}/realms/ancroo/protocol/openid-connect/auth"
update_env_var "OAUTH_TOKEN_URL" "http://keycloak:8080/realms/ancroo/protocol/openid-connect/token"
update_env_var "OAUTH_USERINFO_URL" "http://keycloak:8080/realms/ancroo/protocol/openid-connect/userinfo"
update_env_var "OPENID_PROVIDER_URL" "http://keycloak:8080/realms/ancroo/.well-known/openid-configuration"

print_success "SSO configuration written to .env"

# ─── 6. Test user (optional) ─────────────────────────────
echo ""
if [[ -n "${CREATE_TEST_USER:-}" ]]; then
    # Non-interactive mode
    if [[ "$CREATE_TEST_USER" == "yes" ]]; then
        CLAUDE_TEST_USER="${CLAUDE_TEST_USER:-claude-test}"
        CLAUDE_TEST_PASSWORD=$(openssl rand -base64 24 | tr '+/=' 'Abc')
        update_env_var "CLAUDE_TEST_USER" "$CLAUDE_TEST_USER"
        update_env_var "CLAUDE_TEST_PASSWORD" "$CLAUDE_TEST_PASSWORD"
        print_success "Test user credentials written to .env"
        print_info "User will be created in Keycloak after services start."
    else
        remove_env_var "CLAUDE_TEST_USER" "$PROJECT_ROOT/.env"
        remove_env_var "CLAUDE_TEST_PASSWORD" "$PROJECT_ROOT/.env"
        print_info "Test user skipped"
    fi
elif confirm "Create a test user for automated testing (e.g. Claude Code)?"; then
    CLAUDE_TEST_USER=$(prompt_input "Test username" "claude-test")
    CLAUDE_TEST_PASSWORD=$(openssl rand -base64 24 | tr '+/=' 'Abc')
    update_env_var "CLAUDE_TEST_USER" "$CLAUDE_TEST_USER"
    update_env_var "CLAUDE_TEST_PASSWORD" "$CLAUDE_TEST_PASSWORD"
    print_success "Test user credentials written to .env"
    print_info "User will be created in Keycloak after services start."
else
    # Remove stale test user vars if present
    remove_env_var "CLAUDE_TEST_USER" "$PROJECT_ROOT/.env"
    remove_env_var "CLAUDE_TEST_PASSWORD" "$PROJECT_ROOT/.env"
fi

# ─── 7. Personal user account ───────────────────────────
echo ""
default_username="${ADMIN_EMAIL%%@*}"

if [[ -n "${KEYCLOAK_FIRST_USER:-}" ]]; then
    # Non-interactive: username and email pre-set
    FIRST_USER="$KEYCLOAK_FIRST_USER"
    FIRST_USER_EMAIL="${KEYCLOAK_FIRST_USER_EMAIL:-$ADMIN_EMAIL}"
    FIRST_USER_PASSWORD=$(openssl rand -base64 16 | tr '+/=' 'Abc')
    update_env_var "KEYCLOAK_FIRST_USER" "$FIRST_USER"
    update_env_var "KEYCLOAK_FIRST_USER_EMAIL" "$FIRST_USER_EMAIL"
    update_env_var "KEYCLOAK_FIRST_USER_PASSWORD" "$FIRST_USER_PASSWORD"
    print_success "Personal user '${FIRST_USER}' configured"
    echo -e "  ${YELLOW}SSO Login Password: ${BOLD}${FIRST_USER_PASSWORD}${NC}"
    print_info "Password stored in .env as KEYCLOAK_FIRST_USER_PASSWORD"
elif confirm "Create a personal user account for SSO login?" "y"; then
    FIRST_USER=$(prompt_input "Username" "$default_username")
    FIRST_USER_EMAIL=$(prompt_input "Email" "$ADMIN_EMAIL")
    FIRST_USER_PASSWORD=$(openssl rand -base64 16 | tr '+/=' 'Abc')
    update_env_var "KEYCLOAK_FIRST_USER" "$FIRST_USER"
    update_env_var "KEYCLOAK_FIRST_USER_EMAIL" "$FIRST_USER_EMAIL"
    update_env_var "KEYCLOAK_FIRST_USER_PASSWORD" "$FIRST_USER_PASSWORD"
    print_success "Personal user '${FIRST_USER}' configured"
    echo ""
    echo -e "  ${YELLOW}SSO Login Password: ${BOLD}${FIRST_USER_PASSWORD}${NC}"
    print_info "Save this — it is your login for Open WebUI, n8n, etc."
    print_info "Also stored in .env as KEYCLOAK_FIRST_USER_PASSWORD"
else
    remove_env_var "KEYCLOAK_FIRST_USER" "$PROJECT_ROOT/.env"
    remove_env_var "KEYCLOAK_FIRST_USER_EMAIL" "$PROJECT_ROOT/.env"
    remove_env_var "KEYCLOAK_FIRST_USER_PASSWORD" "$PROJECT_ROOT/.env"
fi

# ─── 8. Generate oauth2-proxy config ─────────────────────
print_step "Generating oauth2-proxy config"

mkdir -p "$PROJECT_ROOT/data/keycloak"

sed -e "s|__KEYCLOAK_DOMAIN__|${KEYCLOAK_DOMAIN}|g" \
    -e "s|__BASE_DOMAIN__|${BASE_DOMAIN}|g" \
    -e "s|__COOKIE_SECRET__|${OAUTH2_PROXY_COOKIE_SECRET}|g" \
    "$SCRIPT_DIR/oauth2-proxy.cfg.template" \
    > "$PROJECT_ROOT/data/keycloak/oauth2-proxy.cfg"

print_success "oauth2-proxy.cfg created (data/keycloak/oauth2-proxy.cfg)"
echo ""
