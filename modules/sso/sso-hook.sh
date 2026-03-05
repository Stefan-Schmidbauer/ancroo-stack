#!/bin/bash
# SSO Hook — Registriert/Entfernt Keycloak-Clients fuer ein Modul
# Wird von module.sh aufgerufen bei enable/disable.
#
# Usage: sso-hook.sh register|unregister <module_name>
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
MODULES_DIR="$PROJECT_ROOT/modules"

# Load common helpers
if [[ -f "$PROJECT_ROOT/tools/install/lib/common.sh" ]]; then
    source "$PROJECT_ROOT/tools/install/lib/common.sh"
else
    print_info() { echo "  -> $1"; }
    print_success() { echo "  OK: $1"; }
    print_warning() { echo "  WARN: $1"; }
    print_error() { echo "  ERROR: $1" >&2; }
fi

# ─── Argument parsing ──────────────────────────────────────
COMMAND="${1:-}"
MODULE_NAME="${2:-}"

if [[ -z "$COMMAND" ]] || [[ -z "$MODULE_NAME" ]]; then
    echo "Usage: sso-hook.sh register|unregister <module_name>"
    exit 1
fi

# ─── Load module configuration ─────────────────────────────
CONF_FILE="$MODULES_DIR/$MODULE_NAME/module.conf"
if [[ ! -f "$CONF_FILE" ]]; then
    print_warning "module.conf nicht gefunden: $MODULE_NAME"
    exit 0
fi

# Reset and source module.conf
MODULE_SSO_TYPE=""
MODULE_SSO_GROUP=""
MODULE_DOMAIN_VAR=""
MODULE_DESCRIPTION=""
source "$CONF_FILE"

# Skip if module has no SSO configuration
if [[ -z "$MODULE_SSO_TYPE" ]]; then
    exit 0
fi

# Default group
if [[ -z "$MODULE_SSO_GROUP" ]]; then
    MODULE_SSO_GROUP="standard-users"
fi

# ─── Load environment ──────────────────────────────────────
if [[ ! -f "$PROJECT_ROOT/.env" ]]; then
    print_error ".env nicht gefunden"
    exit 1
fi

safe_source_env "$PROJECT_ROOT/.env"

# Verify Keycloak admin credentials are available
if [[ -z "${KEYCLOAK_ADMIN_PASSWORD:-}" ]]; then
    print_warning "KEYCLOAK_ADMIN_PASSWORD nicht gesetzt — SSO-Hook uebersprungen"
    print_info "Fuehre 'bash modules/sso/post-enable.sh' aus um Keycloak zu konfigurieren"
    exit 0
fi

# Verify keycloak is running and resolve URL
if ! docker ps --format '{{.Names}}' | grep -q '^keycloak$'; then
    print_warning "keycloak laeuft nicht — SSO-Hook uebersprungen"
    exit 0
fi

source "$SCRIPT_DIR/lib/keycloak-helpers.sh"
KEYCLOAK_URL=$(get_keycloak_url) || exit 0

# Wait for Keycloak to be ready (max 30s) — avoids ConnectionRefused during reconcile_sso
kc_ip=$(echo "$KEYCLOAK_URL" | sed 's|http://||;s|:.*||')
kc_ready=false
for _i in $(seq 1 6); do
    if curl -sf "http://${kc_ip}:9000/health/ready" >/dev/null 2>&1; then
        kc_ready=true
        break
    fi
    sleep 5
done

if ! $kc_ready; then
    print_warning "Keycloak not ready — SSO registration skipped for: $MODULE_NAME"
    exit 0
fi

# Resolve module domain from .env
MODULE_DOMAIN=""
if [[ -n "$MODULE_DOMAIN_VAR" ]]; then
    MODULE_DOMAIN="${!MODULE_DOMAIN_VAR:-}"
fi

# Fallback: construct domain from module name + base domain
if [[ -z "$MODULE_DOMAIN" ]] && [[ -n "${BASE_DOMAIN:-}" ]]; then
    MODULE_DOMAIN="${MODULE_NAME}.${BASE_DOMAIN}"
fi

# Use MODULE_NAME as slug, MODULE_DESCRIPTION as display name
SLUG="$MODULE_NAME"
DISPLAY_NAME="${MODULE_DESCRIPTION:-$MODULE_NAME}"

# ─── Execute command ───────────────────────────────────────
case "$COMMAND" in
    register)
        if [[ "$MODULE_SSO_TYPE" == "proxy" ]]; then
            # Proxy modules are protected by oauth2-proxy ForwardAuth.
            # Keycloak client registration is optional — oauth2-proxy uses
            # a single client (ancroo-proxy) for all proxy-protected services.
            print_success "Proxy-SSO aktiviert fuer: $MODULE_NAME (via keycloak-forward-auth Middleware)"

            # Some proxy modules also need their own Keycloak client
            # (e.g., ancroo needs a public PKCE client for the browser extension)
            SSO_SETUP="$MODULES_DIR/$MODULE_NAME/sso-setup.sh"
            if [[ -f "$SSO_SETUP" ]]; then
                print_info "Additional SSO setup for proxy module: $MODULE_NAME"
                bash "$SSO_SETUP" || print_warning "SSO-Setup fehlgeschlagen fuer: $MODULE_NAME"
            fi

        elif [[ "$MODULE_SSO_TYPE" == "oauth2" ]]; then
            # OAuth2 modules need their own Keycloak client
            SSO_SETUP="$MODULES_DIR/$MODULE_NAME/sso-setup.sh"
            if [[ -f "$SSO_SETUP" ]]; then
                print_info "OAuth2 SSO-Setup fuer: $MODULE_NAME"
                bash "$SSO_SETUP" || print_warning "OAuth2 SSO-Setup fehlgeschlagen fuer: $MODULE_NAME"
            else
                # Try generic client registration
                python3 "$SCRIPT_DIR/keycloak-client-manager.py" \
                    register \
                    --admin-user "${KEYCLOAK_ADMIN:-admin}" \
                    --admin-password "$KEYCLOAK_ADMIN_PASSWORD" \
                    --keycloak-url "$KEYCLOAK_URL" \
                    --realm "${KEYCLOAK_REALM:-ancroo}" \
                    --client-id "$SLUG" \
                    --display-name "$DISPLAY_NAME" \
                    --redirect-uri "https://${MODULE_DOMAIN}/callback" \
                    --sso-group "$MODULE_SSO_GROUP" \
                    || print_warning "OAuth2 Client-Registrierung fehlgeschlagen fuer: $MODULE_NAME"
            fi
        fi
        ;;

    unregister)
        if [[ "$MODULE_SSO_TYPE" == "proxy" ]]; then
            # Proxy modules don't have individual Keycloak clients
            print_success "Proxy-SSO deaktiviert fuer: $MODULE_NAME"

        elif [[ "$MODULE_SSO_TYPE" == "oauth2" ]]; then
            SSO_TEARDOWN="$MODULES_DIR/$MODULE_NAME/sso-teardown.sh"
            if [[ -f "$SSO_TEARDOWN" ]]; then
                bash "$SSO_TEARDOWN" || print_warning "OAuth2 SSO-Teardown fehlgeschlagen fuer: $MODULE_NAME"
            else
                python3 "$SCRIPT_DIR/keycloak-client-manager.py" \
                    unregister \
                    --admin-user "${KEYCLOAK_ADMIN:-admin}" \
                    --admin-password "$KEYCLOAK_ADMIN_PASSWORD" \
                    --keycloak-url "$KEYCLOAK_URL" \
                    --realm "${KEYCLOAK_REALM:-ancroo}" \
                    --client-id "$SLUG" \
                    || print_warning "OAuth2 Client-Entfernung fehlgeschlagen fuer: $MODULE_NAME"
            fi
        fi
        ;;

    *)
        echo "ERROR: Unbekannter Befehl: $COMMAND"
        echo "Usage: sso-hook.sh register|unregister <module_name>"
        exit 1
        ;;
esac
