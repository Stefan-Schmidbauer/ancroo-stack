#!/bin/bash
# SSO User Manager — CLI wrapper for Keycloak Admin REST API
#
# Usage:
#   sso-user-manager.sh add-user <email> [--group admin-users|standard-users] [--password <pw>] [--first-name <name>] [--last-name <name>]
#   sso-user-manager.sh list-users
#   sso-user-manager.sh reset-password <email>
#   sso-user-manager.sh delete-user <email>
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# Load common helpers
if [[ -f "$PROJECT_ROOT/tools/install/lib/common.sh" ]]; then
    source "$PROJECT_ROOT/tools/install/lib/common.sh"
else
    print_info() { echo "  -> $1"; }
    print_success() { echo "  OK: $1"; }
    print_warning() { echo "  WARN: $1"; }
    print_error() { echo "  ERROR: $1" >&2; }
fi

# ─── Load environment ──────────────────────────────────────
if [[ ! -f "$PROJECT_ROOT/.env" ]]; then
    print_error ".env nicht gefunden"
    exit 1
fi

safe_source_env "$PROJECT_ROOT/.env"

source "$SCRIPT_DIR/lib/keycloak-helpers.sh"
KEYCLOAK_URL=$(get_keycloak_url) || exit 1
REALM="${KEYCLOAK_REALM:-ancroo}"
ADMIN_USER="${KEYCLOAK_ADMIN:-admin}"
ADMIN_PASSWORD="${KEYCLOAK_ADMIN_PASSWORD:-}"

if [[ -z "$ADMIN_PASSWORD" ]]; then
    print_error "KEYCLOAK_ADMIN_PASSWORD nicht gesetzt"
    exit 1
fi

# ─── Helper: Get admin token ──────────────────────────────
get_token() {
    curl -sf "$KEYCLOAK_URL/realms/master/protocol/openid-connect/token" \
        -d "grant_type=password" \
        -d "client_id=admin-cli" \
        -d "username=$ADMIN_USER" \
        -d "password=$ADMIN_PASSWORD" \
        | python3 -c "import sys,json; print(json.load(sys.stdin)['access_token'])"
}

# ─── Helper: API call ─────────────────────────────────────
kc_api() {
    local method="$1"
    local path="$2"
    shift 2
    local token
    token=$(get_token)
    curl -sf -X "$method" \
        "$KEYCLOAK_URL/admin/realms/$REALM$path" \
        -H "Authorization: Bearer $token" \
        -H "Content-Type: application/json" \
        "$@"
}

# ─── Commands ──────────────────────────────────────────────
COMMAND="${1:-}"
shift || true

case "$COMMAND" in
    add-user)
        EMAIL="${1:-}"
        if [[ -z "$EMAIL" ]]; then
            echo "Usage: sso-user-manager.sh add-user <email> [--group admin-users|standard-users] [--password <pw>] [--first-name <name>] [--last-name <name>]"
            exit 1
        fi
        shift

        GROUP="standard-users"
        PASSWORD=""
        FIRST_NAME=""
        LAST_NAME=""
        TEMP_PW=true

        while [[ $# -gt 0 ]]; do
            case "$1" in
                --group) GROUP="$2"; shift 2 ;;
                --password) PASSWORD="$2"; TEMP_PW=false; shift 2 ;;
                --first-name) FIRST_NAME="$2"; shift 2 ;;
                --last-name) LAST_NAME="$2"; shift 2 ;;
                *) shift ;;
            esac
        done

        # Generate password if not provided
        if [[ -z "$PASSWORD" ]]; then
            PASSWORD=$(openssl rand -base64 12 | tr '+/=' 'Abc')
        fi

        # Extract username from email
        USERNAME="${EMAIL%%@*}"

        # Default firstName/lastName from email (Keycloak 26.x requires these)
        if [[ -z "$FIRST_NAME" ]]; then
            # Capitalize first letter of username part
            FIRST_NAME="$(echo "${USERNAME}" | sed 's/\b\(.\)/\u\1/')"
        fi
        if [[ -z "$LAST_NAME" ]]; then
            # Use domain part of email
            LAST_NAME="${EMAIL#*@}"
        fi

        # Create user
        kc_api POST "/users" \
            -d "{
                \"username\": \"$USERNAME\",
                \"email\": \"$EMAIL\",
                \"firstName\": \"$FIRST_NAME\",
                \"lastName\": \"$LAST_NAME\",
                \"enabled\": true,
                \"emailVerified\": true,
                \"credentials\": [{
                    \"type\": \"password\",
                    \"value\": \"$PASSWORD\",
                    \"temporary\": $TEMP_PW
                }]
            }" && print_success "User '$EMAIL' erstellt" || {
            print_error "User konnte nicht erstellt werden (existiert evtl. bereits)"
            exit 1
        }

        # Find user ID
        USER_ID=$(kc_api GET "/users?email=$EMAIL" | python3 -c "import sys,json; users=json.load(sys.stdin); print(users[0]['id'] if users else '')")

        if [[ -n "$USER_ID" ]]; then
            # Find group ID
            GROUP_ID=$(kc_api GET "/groups?search=$GROUP" | python3 -c "import sys,json; groups=json.load(sys.stdin); print(next((g['id'] for g in groups if g['name']=='$GROUP'), ''))")

            if [[ -n "$GROUP_ID" ]]; then
                kc_api PUT "/users/$USER_ID/groups/$GROUP_ID" && \
                    print_success "User zu Gruppe '$GROUP' hinzugefuegt"
            fi
        fi

        echo ""
        echo "  E-Mail:    $EMAIL"
        echo "  Gruppe:    $GROUP"
        if $TEMP_PW; then
            echo "  Passwort:  $PASSWORD (temporaer — wird bei erstem Login geaendert)"
        else
            echo "  Passwort:  ********"
        fi
        ;;

    list-users)
        USERS=$(kc_api GET "/users?max=100")
        echo "$USERS" | python3 -c "
import sys, json
users = json.load(sys.stdin)
if not users:
    print('  Keine User gefunden')
    sys.exit()
print(f'  {len(users)} User:')
print()
fmt = '  {:<30} {:<25} {:<10}'
print(fmt.format('E-Mail', 'Username', 'Enabled'))
print(fmt.format('─' * 30, '─' * 25, '─' * 10))
for u in users:
    print(fmt.format(u.get('email', '-'), u.get('username', '-'), str(u.get('enabled', False))))
"
        ;;

    reset-password)
        EMAIL="${1:-}"
        if [[ -z "$EMAIL" ]]; then
            echo "Usage: sso-user-manager.sh reset-password <email>"
            exit 1
        fi

        NEW_PW=$(openssl rand -base64 12 | tr '+/=' 'Abc')

        USER_ID=$(kc_api GET "/users?email=$EMAIL" | python3 -c "import sys,json; users=json.load(sys.stdin); print(users[0]['id'] if users else '')")

        if [[ -z "$USER_ID" ]]; then
            print_error "User '$EMAIL' nicht gefunden"
            exit 1
        fi

        kc_api PUT "/users/$USER_ID/reset-password" \
            -d "{\"type\": \"password\", \"value\": \"$NEW_PW\", \"temporary\": true}" && \
            print_success "Passwort zurueckgesetzt fuer '$EMAIL'"

        echo "  Neues Passwort: $NEW_PW (temporaer — wird bei naechstem Login geaendert)"
        ;;

    delete-user)
        EMAIL="${1:-}"
        if [[ -z "$EMAIL" ]]; then
            echo "Usage: sso-user-manager.sh delete-user <email>"
            exit 1
        fi

        USER_ID=$(kc_api GET "/users?email=$EMAIL" | python3 -c "import sys,json; users=json.load(sys.stdin); print(users[0]['id'] if users else '')")

        if [[ -z "$USER_ID" ]]; then
            print_error "User '$EMAIL' nicht gefunden"
            exit 1
        fi

        kc_api DELETE "/users/$USER_ID" && \
            print_success "User '$EMAIL' geloescht"
        ;;

    *)
        echo "SSO User Manager — Keycloak"
        echo ""
        echo "Usage:"
        echo "  sso-user-manager.sh add-user <email> [--group admin-users|standard-users] [--password <pw>] [--first-name <name>] [--last-name <name>]"
        echo "  sso-user-manager.sh list-users"
        echo "  sso-user-manager.sh reset-password <email>"
        echo "  sso-user-manager.sh delete-user <email>"
        exit 1
        ;;
esac
