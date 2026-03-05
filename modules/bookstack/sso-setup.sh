#!/bin/bash
# BookStack SSO Setup — Registers BookStack as OAuth2 client in Keycloak
# Called by sso-hook.sh when BookStack is enabled after SSO,
# or when SSO is enabled while BookStack is already active.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
SSO_DIR="$PROJECT_ROOT/modules/sso"
ENV_FILE="$PROJECT_ROOT/.env"

source "$PROJECT_ROOT/tools/install/lib/common.sh" 2>/dev/null || {
    print_info() { echo "  -> $1"; }
    print_success() { echo "  OK: $1"; }
    print_warning() { echo "  WARN: $1"; }
    update_env_var() {
        local key="$1" value="$2"
        local temp_file
        temp_file=$(mktemp "${ENV_FILE}.XXXXXX")
        if grep -q "^${key}=" "$ENV_FILE"; then
            while IFS= read -r line; do
                if [[ "$line" =~ ^${key}= ]]; then
                    echo "${key}=\"${value}\"" >> "$temp_file"
                else
                    echo "$line" >> "$temp_file"
                fi
            done < "$ENV_FILE"
            mv "$temp_file" "$ENV_FILE"
        else
            rm -f "$temp_file"
            echo "${key}=\"${value}\"" >> "$ENV_FILE"
        fi
    }
}

# Load environment (safe_source_env handles special chars in passwords)
safe_source_env "$ENV_FILE"

# Resolve Keycloak URL via container IP (no host port mapping)
source "$SSO_DIR/lib/keycloak-helpers.sh"
KEYCLOAK_URL=$(get_keycloak_url) || { print_warning "Keycloak URL nicht ermittelbar"; exit 1; }

BOOKSTACK_DOMAIN="${BOOKSTACK_DOMAIN:-bookstack.${BASE_DOMAIN:-localhost}}"

print_info "Registriere BookStack OAuth2 Client in Keycloak..."

# Register client via keycloak-client-manager.py
REGISTER_OUTPUT=$(python3 "$SSO_DIR/keycloak-client-manager.py" \
    register \
    --admin-user "${KEYCLOAK_ADMIN:-admin}" \
    --admin-password "$KEYCLOAK_ADMIN_PASSWORD" \
    --keycloak-url "$KEYCLOAK_URL" \
    --realm "${KEYCLOAK_REALM:-ancroo}" \
    --client-id "bookstack" \
    --display-name "BookStack Wiki" \
    --redirect-uri "https://${BOOKSTACK_DOMAIN}/oidc/callback" \
    --sso-group "standard-users" \
    2>&1) || {
    print_warning "BookStack OAuth2 Client-Registrierung fehlgeschlagen"
    echo "$REGISTER_OUTPUT"
    exit 1
}

echo "$REGISTER_OUTPUT"

# Extract client secret from output
CLIENT_SECRET=$(echo "$REGISTER_OUTPUT" | grep "CLIENT_SECRET=" | cut -d= -f2-)

if [[ -n "$CLIENT_SECRET" ]]; then
    update_env_var "BOOKSTACK_OIDC_CLIENT_ID" "bookstack"
    update_env_var "BOOKSTACK_OIDC_CLIENT_SECRET" "$CLIENT_SECRET"
    update_env_var "BOOKSTACK_AUTH_METHOD" "oidc"
    update_env_var "BOOKSTACK_OIDC_ISSUER" "https://auth.${BASE_DOMAIN:-localhost}/realms/${KEYCLOAK_REALM:-ancroo}"
    update_env_var "BOOKSTACK_APP_URL" "https://${BOOKSTACK_DOMAIN}"
    print_success "BookStack OIDC Credentials konfiguriert"

    # ─── Link existing admin user to Keycloak identity ─────
    # BookStack does not auto-merge local users with OIDC by email.
    # If the admin user (ID=1) has the same email as a Keycloak user
    # but no external_auth_id, OIDC login fails with an email conflict.
    # Fix: Set external_auth_id to the Keycloak user's UUID.
    ADMIN_EMAIL="${BOOKSTACK_ADMIN_EMAIL:-}"
    if [[ -n "$ADMIN_EMAIL" ]] && docker ps --format '{{.Names}}' | grep -q '^bookstack$'; then
        print_info "Linking BookStack admin to Keycloak identity..."

        # Get admin token for Keycloak API
        KC_TOKEN=$(curl -sf "$KEYCLOAK_URL/realms/master/protocol/openid-connect/token" \
            -d "grant_type=password" \
            -d "client_id=admin-cli" \
            -d "username=${KEYCLOAK_ADMIN:-admin}" \
            -d "password=$KEYCLOAK_ADMIN_PASSWORD" \
            | python3 -c "import sys,json; print(json.load(sys.stdin).get('access_token',''))" 2>/dev/null) || true

        if [[ -n "$KC_TOKEN" ]]; then
            # Look up Keycloak user by email
            KC_USER_ID=$(curl -sf "$KEYCLOAK_URL/admin/realms/${KEYCLOAK_REALM:-ancroo}/users?email=$(python3 -c "import urllib.parse; print(urllib.parse.quote('$ADMIN_EMAIL'))")&exact=true" \
                -H "Authorization: Bearer $KC_TOKEN" \
                | python3 -c "import sys,json; users=json.load(sys.stdin); print(users[0]['id'] if users else '')" 2>/dev/null) || true

            if [[ -n "$KC_USER_ID" ]]; then
                # Wait for BookStack to be healthy before running tinker
                WAITED=0
                while [[ $WAITED -lt 60 ]]; do
                    if docker exec bookstack curl -sf http://localhost:80/status >/dev/null 2>&1; then
                        break
                    fi
                    sleep 3
                    WAITED=$((WAITED + 3))
                done

                TINKER_CMD="\$user = \\BookStack\\Users\\Models\\User::find(1); if (\$user && empty(\$user->external_auth_id)) { \$user->external_auth_id = '${KC_USER_ID}'; \$user->save(); echo 'LINKED'; }"
                LINK_RESULT=$(docker exec bookstack php /app/www/artisan tinker --execute="$TINKER_CMD" 2>&1) || true

                if echo "$LINK_RESULT" | grep -q "LINKED"; then
                    print_success "Admin user linked to Keycloak ($KC_USER_ID)"
                else
                    print_info "Admin user already linked or link not needed"
                fi
            else
                print_info "No matching Keycloak user for $ADMIN_EMAIL — skipping link"
            fi
        else
            print_warning "Could not obtain Keycloak token — admin link skipped"
        fi
    fi

    # Restart BookStack to load new credentials
    if docker ps --format '{{.Names}}' | grep -q '^bookstack$'; then
        docker restart bookstack 2>/dev/null || true
        print_success "BookStack neugestartet"
    fi
else
    print_warning "Kein Client Secret erhalten — manuelle Konfiguration noetig"
fi
