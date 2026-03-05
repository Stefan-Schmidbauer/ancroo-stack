#!/bin/bash
# SSO Module — Post-Enable Script
# Wird von module.sh aufgerufen NACHDEM Keycloak-Services gestartet sind.
# Konfiguriert Keycloak Realm, Clients und Gruppen ueber die Admin REST API.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# Load common helpers (includes update_env_var)
source "$PROJECT_ROOT/tools/install/lib/common.sh"

# ─── 1. Warten bis Keycloak bereit ist ──────────────────
print_header "SSO — Keycloak konfigurieren"

print_step "Warte auf Keycloak..."

MAX_WAIT=180
WAITED=0
while true; do
    # Query health via Docker network (Keycloak image has no curl)
    kc_ip=$(docker inspect keycloak --format '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' 2>/dev/null)
    HEALTH=$(curl -sf "http://${kc_ip:-localhost}:9000/health/ready" 2>/dev/null || true)
    if echo "$HEALTH" | grep -q '"status".*"UP"' 2>/dev/null; then
        break
    fi
    if [[ $WAITED -ge $MAX_WAIT ]]; then
        print_error "Keycloak nicht bereit nach ${MAX_WAIT}s"
        print_info "Starte die Konfiguration spaeter manuell:"
        print_info "  bash modules/sso/post-enable.sh"
        exit 1
    fi
    sleep 5
    WAITED=$((WAITED + 5))
    echo -ne "  Warte... (${WAITED}s)\r"
done
echo ""
print_success "Keycloak ist bereit"

# ─── 2. Keycloak Realm und Clients konfigurieren ────────
print_step "Keycloak Realm und Clients konfigurieren..."

safe_source_env "$PROJECT_ROOT/.env"

BASE_DOMAIN="${BASE_DOMAIN:-localhost}"
KEYCLOAK_DOMAIN="${KEYCLOAK_DOMAIN:-auth.${BASE_DOMAIN}}"
KEYCLOAK_ADMIN="${KEYCLOAK_ADMIN:-admin}"
KEYCLOAK_ADMIN_PASSWORD="${KEYCLOAK_ADMIN_PASSWORD}"

source "$SCRIPT_DIR/lib/keycloak-helpers.sh"
KEYCLOAK_URL=$(get_keycloak_url) || exit 1

# keycloak-setup.py auf dem Host ausfuehren (nutzt Keycloak REST API via Docker-Netzwerk)
SETUP_OUTPUT=$(python3 "$SCRIPT_DIR/keycloak-setup.py" \
    --admin-user "$KEYCLOAK_ADMIN" \
    --admin-password "$KEYCLOAK_ADMIN_PASSWORD" \
    --base-domain "$BASE_DOMAIN" \
    --keycloak-url "$KEYCLOAK_URL" \
    2>&1) || {
    print_error "Keycloak Setup fehlgeschlagen"
    echo "$SETUP_OUTPUT"
    exit 1
}

echo "$SETUP_OUTPUT"

# ─── 3. Secrets aus Setup-Output extrahieren ─────────────
print_step ".env aktualisieren..."

# Extract secrets from JSON output (keycloak-setup.py prints KEY=VALUE lines)
OPENWEBUI_SECRET=$(echo "$SETUP_OUTPUT" | grep "^OPEN_WEBUI_CLIENT_SECRET=" | cut -d= -f2-)
BOOKSTACK_SECRET=$(echo "$SETUP_OUTPUT" | grep "^BOOKSTACK_CLIENT_SECRET=" | cut -d= -f2-)
PROXY_SECRET=$(echo "$SETUP_OUTPUT" | grep "^OAUTH2_PROXY_CLIENT_SECRET=" | cut -d= -f2-)

if [[ -n "$OPENWEBUI_SECRET" ]]; then
    update_env_var "OAUTH_CLIENT_ID" "open-webui"
    update_env_var "OAUTH_CLIENT_SECRET" "$OPENWEBUI_SECRET"
    print_success "Open WebUI OAuth Credentials aktualisiert"
fi

if [[ -n "$BOOKSTACK_SECRET" ]]; then
    update_env_var "BOOKSTACK_OIDC_CLIENT_ID" "bookstack"
    update_env_var "BOOKSTACK_OIDC_CLIENT_SECRET" "$BOOKSTACK_SECRET"
    update_env_var "BOOKSTACK_AUTH_METHOD" "oidc"
    update_env_var "BOOKSTACK_OIDC_ISSUER" "https://auth.${BASE_DOMAIN}/realms/${KEYCLOAK_REALM:-ancroo}"
    print_success "BookStack OIDC Credentials aktualisiert"
fi

if [[ -n "$PROXY_SECRET" ]]; then
    update_env_var "OAUTH2_PROXY_CLIENT_SECRET" "$PROXY_SECRET"
    print_success "oauth2-proxy Client Secret aktualisiert"

    # oauth2-proxy.cfg mit echtem Secret aktualisieren (atomic write)
    local cfg_file="$PROJECT_ROOT/data/keycloak/oauth2-proxy.cfg"
    if [[ -f "$cfg_file" ]]; then
        local cfg_tmp
        cfg_tmp=$(mktemp "${cfg_file}.XXXXXX")
        sed "s|client_secret = .*|client_secret = \"${PROXY_SECRET}\"|" \
            "$cfg_file" > "$cfg_tmp"
        mv "$cfg_tmp" "$cfg_file"
    fi
fi

# ─── 4. oauth2-proxy neustarten (neues Client Secret) ───
print_step "oauth2-proxy neustarten..."
docker restart oauth2-proxy 2>/dev/null || true
sleep 3

# ─── 5. Services mit neuen OAuth Credentials neustarten ───
# Compose overlays (compose.openwebui.yml, compose.bookstack.yml, compose.sso.yml)
# and SSO module registration are handled by reconcile_compose() / reconcile_sso()
# in module.sh after this script completes.
print_step "Services mit OAuth Credentials neustarten..."

cd "$PROJECT_ROOT"
safe_source_env "$PROJECT_ROOT/.env"

if docker ps --format '{{.Names}}' | grep -q '^open-webui$'; then
    docker compose up -d open-webui
    print_success "Open WebUI mit OAuth Credentials neu erstellt"
fi

if docker ps --format '{{.Names}}' | grep -q '^bookstack$'; then
    docker compose up -d bookstack
    print_success "BookStack mit OIDC Credentials neu erstellt"
fi

sleep 3

# ─── 6. Test user (if configured in setup.sh) ────────────
if [[ -n "${CLAUDE_TEST_USER:-}" && -n "${CLAUDE_TEST_PASSWORD:-}" ]]; then
    print_step "Creating test user '${CLAUDE_TEST_USER}'..."
    REALM="${KEYCLOAK_REALM:-ancroo}"

    # Get admin token
    KC_TOKEN=$(curl -sf "$KEYCLOAK_URL/realms/master/protocol/openid-connect/token" \
        -d "grant_type=password" \
        -d "client_id=admin-cli" \
        -d "username=${KEYCLOAK_ADMIN}" \
        --data-urlencode "password=${KEYCLOAK_ADMIN_PASSWORD}" \
        | python3 -c "import sys,json; print(json.load(sys.stdin)['access_token'])")

    # Check if user already exists
    EXISTING=$(curl -sf "$KEYCLOAK_URL/admin/realms/$REALM/users?username=${CLAUDE_TEST_USER}&exact=true" \
        -H "Authorization: Bearer $KC_TOKEN" \
        | python3 -c "import sys,json; print(len(json.load(sys.stdin)))")

    if [[ "$EXISTING" -gt 0 ]]; then
        print_info "Test user '${CLAUDE_TEST_USER}' already exists — skipping"
    else
        # Create user with permanent password
        HTTP_CODE=$(curl -sf -o /dev/null -w "%{http_code}" \
            "$KEYCLOAK_URL/admin/realms/$REALM/users" \
            -H "Authorization: Bearer $KC_TOKEN" \
            -H "Content-Type: application/json" \
            -d "{
                \"username\": \"${CLAUDE_TEST_USER}\",
                \"email\": \"${CLAUDE_TEST_USER}@test.local\",
                \"firstName\": \"Claude\",
                \"lastName\": \"Test\",
                \"enabled\": true,
                \"emailVerified\": true,
                \"credentials\": [{
                    \"type\": \"password\",
                    \"value\": \"${CLAUDE_TEST_PASSWORD}\",
                    \"temporary\": false
                }]
            }")

        if [[ "$HTTP_CODE" == "201" ]]; then
            # Add to standard-users group
            USER_ID=$(curl -sf "$KEYCLOAK_URL/admin/realms/$REALM/users?username=${CLAUDE_TEST_USER}&exact=true" \
                -H "Authorization: Bearer $KC_TOKEN" \
                | python3 -c "import sys,json; print(json.load(sys.stdin)[0]['id'])")
            GROUP_ID=$(curl -sf "$KEYCLOAK_URL/admin/realms/$REALM/groups?search=standard-users" \
                -H "Authorization: Bearer $KC_TOKEN" \
                | python3 -c "import sys,json; print(next((g['id'] for g in json.load(sys.stdin) if g['name']=='standard-users'), ''))")
            if [[ -n "$USER_ID" && -n "$GROUP_ID" ]]; then
                curl -sf -X PUT "$KEYCLOAK_URL/admin/realms/$REALM/users/$USER_ID/groups/$GROUP_ID" \
                    -H "Authorization: Bearer $KC_TOKEN" \
                    -H "Content-Type: application/json" 2>/dev/null || true
            fi
            print_success "Test user '${CLAUDE_TEST_USER}' created (group: standard-users)"
        else
            print_warning "Could not create test user (HTTP $HTTP_CODE)"
        fi
    fi
fi

# ─── 7. Personal user (if configured in setup.sh) ───────
if [[ -n "${KEYCLOAK_FIRST_USER:-}" && -n "${KEYCLOAK_FIRST_USER_PASSWORD:-}" ]]; then
    print_step "Creating personal user '${KEYCLOAK_FIRST_USER}'..."
    REALM="${KEYCLOAK_REALM:-ancroo}"

    # Re-use or get fresh admin token
    if [[ -z "${KC_TOKEN:-}" ]]; then
        KC_TOKEN=$(curl -sf "$KEYCLOAK_URL/realms/master/protocol/openid-connect/token" \
            -d "grant_type=password" \
            -d "client_id=admin-cli" \
            -d "username=${KEYCLOAK_ADMIN}" \
            --data-urlencode "password=${KEYCLOAK_ADMIN_PASSWORD}" \
            | python3 -c "import sys,json; print(json.load(sys.stdin)['access_token'])")
    fi

    EXISTING=$(curl -sf "$KEYCLOAK_URL/admin/realms/$REALM/users?username=${KEYCLOAK_FIRST_USER}&exact=true" \
        -H "Authorization: Bearer $KC_TOKEN" \
        | python3 -c "import sys,json; print(len(json.load(sys.stdin)))")

    if [[ "$EXISTING" -gt 0 ]]; then
        print_info "User '${KEYCLOAK_FIRST_USER}' already exists — skipping"
    else
        HTTP_CODE=$(curl -sf -o /dev/null -w "%{http_code}" \
            "$KEYCLOAK_URL/admin/realms/$REALM/users" \
            -H "Authorization: Bearer $KC_TOKEN" \
            -H "Content-Type: application/json" \
            -d "{
                \"username\": \"${KEYCLOAK_FIRST_USER}\",
                \"email\": \"${KEYCLOAK_FIRST_USER_EMAIL:-${KEYCLOAK_FIRST_USER}@${BASE_DOMAIN}}\",
                \"firstName\": \"${KEYCLOAK_FIRST_USER}\",
                \"lastName\": \"User\",
                \"enabled\": true,
                \"emailVerified\": true,
                \"credentials\": [{
                    \"type\": \"password\",
                    \"value\": \"${KEYCLOAK_FIRST_USER_PASSWORD}\",
                    \"temporary\": false
                }]
            }")

        if [[ "$HTTP_CODE" == "201" ]]; then
            USER_ID=$(curl -sf "$KEYCLOAK_URL/admin/realms/$REALM/users?username=${KEYCLOAK_FIRST_USER}&exact=true" \
                -H "Authorization: Bearer $KC_TOKEN" \
                | python3 -c "import sys,json; print(json.load(sys.stdin)[0]['id'])")
            GROUP_ID=$(curl -sf "$KEYCLOAK_URL/admin/realms/$REALM/groups?search=standard-users" \
                -H "Authorization: Bearer $KC_TOKEN" \
                | python3 -c "import sys,json; print(next((g['id'] for g in json.load(sys.stdin) if g['name']=='standard-users'), ''))")
            if [[ -n "$USER_ID" && -n "$GROUP_ID" ]]; then
                curl -sf -X PUT "$KEYCLOAK_URL/admin/realms/$REALM/users/$USER_ID/groups/$GROUP_ID" \
                    -H "Authorization: Bearer $KC_TOKEN" \
                    -H "Content-Type: application/json" 2>/dev/null || true
            fi
            print_success "User '${KEYCLOAK_FIRST_USER}' created (group: standard-users)"
        else
            print_warning "Could not create personal user (HTTP $HTTP_CODE)"
        fi
    fi
fi

# ─── Fertig ──────────────────────────────────────────────
print_header "SSO Setup abgeschlossen!"

echo -e "  ${GREEN}Konfigurierte Services:${NC}"
echo ""
echo "  Keycloak:    https://${KEYCLOAK_DOMAIN}/admin"
echo "               Admin: ${KEYCLOAK_ADMIN}"
echo "               Realm: ancroo"
echo ""

if [[ -n "${KEYCLOAK_FIRST_USER:-}" && -n "${KEYCLOAK_FIRST_USER_PASSWORD:-}" ]]; then
    echo -e "  ${GREEN}Your SSO Login:${NC}"
    echo "               Username: ${KEYCLOAK_FIRST_USER}"
    echo -e "               Password: ${YELLOW}${KEYCLOAK_FIRST_USER_PASSWORD}${NC}"
    echo "               (also stored in .env as KEYCLOAK_FIRST_USER_PASSWORD)"
    echo ""
fi

echo -e "  ${YELLOW}DNS required:${NC} Add hosts entries if not using a local DNS resolver:"
echo "               ./module.sh urls <HOST_IP>"
echo ""
echo "  Open WebUI:  https://${OPENWEBUI_DOMAIN:-webui.${BASE_DOMAIN}}"
echo "               -> 'Sign in with Keycloak'"
echo ""

if docker ps --format '{{.Names}}' | grep -q '^bookstack$'; then
    echo "  BookStack:   https://${BOOKSTACK_DOMAIN:-bookstack.${BASE_DOMAIN}}"
    echo "               -> 'Login with Keycloak'"
    echo ""
fi

echo -e "  ${GREEN}════════════════════════════════════════════════════════════${NC}"
echo -e "  ${GREEN}  SSO Setup erfolgreich!${NC}"
echo -e "  ${GREEN}════════════════════════════════════════════════════════════${NC}"
echo ""
