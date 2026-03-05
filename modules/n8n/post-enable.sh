#!/bin/bash
# n8n Module — Post-Enable Script
#
# Waits for n8n to become healthy, then automatically provisions:
#   1. Owner account via /rest/owner/setup (if needed)
#   2. Login via /rest/login
#   3. API key via /rest/api-keys
#   4. Writes ANCROO_N8N_API_KEY to .env for the Ancroo Backend
#
# If the owner was already set up (e.g. via UI), and credentials are
# stored in .env (N8N_ADMIN_EMAIL/PASSWORD), login + API key creation
# is still attempted.
#
# Re-run via: ./module.sh setup n8n
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
ENV_FILE="$PROJECT_ROOT/.env"

source "$PROJECT_ROOT/tools/install/lib/common.sh" 2>/dev/null || {
    print_info()    { echo "  → $1"; }
    print_success() { echo "  ✓ $1"; }
    print_warning() { echo "  ⚠ $1"; }
    print_step()    { echo "  ▸ $1"; }
    safe_source_env() { set -a; source "$1"; set +a; }
}

safe_source_env "$ENV_FILE"

# Read a value from .env
get_env_value() {
    grep "^${1}=" "$ENV_FILE" 2>/dev/null | cut -d= -f2- | tr -d '"' || echo ""
}

# Set or update a value in .env
set_env_value() {
    local key="$1" value="$2"
    local entry="${key}=\"${value}\""
    if grep -q "^${key}=" "$ENV_FILE" 2>/dev/null; then
        grep -v "^${key}=" "$ENV_FILE" > "${ENV_FILE}.tmp"
        echo "$entry" >> "${ENV_FILE}.tmp"
        mv "${ENV_FILE}.tmp" "$ENV_FILE"
    else
        echo "$entry" >> "$ENV_FILE"
    fi
}

# ─── Wait for n8n health ──────────────────────────────────
N8N_HOST=$(docker inspect n8n --format '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' 2>/dev/null || true)
if [[ -z "$N8N_HOST" ]]; then
    print_warning "n8n container not found — post-enable skipped"
    return 0 2>/dev/null || exit 0
fi

N8N_URL="http://${N8N_HOST}:5678"

MAX_WAIT=120
WAITED=0
while true; do
    if wget -qO- "${N8N_URL}/healthz" >/dev/null 2>&1; then
        break
    fi
    if [[ $WAITED -ge $MAX_WAIT ]]; then
        print_warning "n8n not ready after ${MAX_WAIT}s — post-enable skipped"
        return 0 2>/dev/null || exit 0
    fi
    sleep 5
    WAITED=$((WAITED + 5))
done

print_success "n8n is running"

# ─── Wait for n8n REST API to be fully ready ──────────────
# /healthz passes before the REST API is initialized.
# Wait until /rest/settings responds with valid JSON.
WAITED=0
while true; do
    if wget -qO- "${N8N_URL}/rest/settings" 2>/dev/null | grep -q '"data"'; then
        break
    fi
    if [[ $WAITED -ge $MAX_WAIT ]]; then
        print_warning "n8n REST API not ready after ${MAX_WAIT}s — post-enable skipped"
        return 0 2>/dev/null || exit 0
    fi
    sleep 5
    WAITED=$((WAITED + 5))
done

print_success "n8n REST API is ready"

# ─── Check if API key already exists ──────────────────────
existing_key=$(get_env_value "ANCROO_N8N_API_KEY")
if [[ -n "$existing_key" ]] && [[ "$existing_key" != CHANGE_ME* ]]; then
    print_info "n8n API key already configured — skipping provisioning"
    print_info "Access: http://${HOST_IP:-localhost}:${N8N_PORT:-5678}"
    return 0 2>/dev/null || exit 0
fi

# ─── Temp dir for JSON payloads (curl body-parser workaround) ─
TMPDIR=$(mktemp -d)
trap 'rm -rf "$TMPDIR"' EXIT

# ─── Step 1: Create owner (if first access) ──────────────
N8N_ADMIN_EMAIL=$(get_env_value "N8N_ADMIN_EMAIL")
N8N_ADMIN_PASSWORD=$(get_env_value "N8N_ADMIN_PASSWORD")

SETUP_NEEDED=$(wget -qO- "${N8N_URL}/rest/settings" 2>/dev/null \
    | grep -o '"showSetupOnFirstLoad":true' || true)

if [[ -n "$SETUP_NEEDED" ]]; then
    # First access — create owner account
    N8N_ADMIN_EMAIL="admin@ancroo.local"
    N8N_ADMIN_PASSWORD="A$(openssl rand -hex 15)"

    printf '{"email":"%s","firstName":"Admin","lastName":"Ancroo","password":"%s"}' \
        "$N8N_ADMIN_EMAIL" "$N8N_ADMIN_PASSWORD" > "$TMPDIR/setup.json"

    SETUP_RESP=$(curl -s -X POST "${N8N_URL}/rest/owner/setup" \
        -H "Content-Type: application/json" \
        -d @"$TMPDIR/setup.json" 2>&1)

    if echo "$SETUP_RESP" | grep -q '"email"'; then
        print_success "n8n owner account created ($N8N_ADMIN_EMAIL)"
        # Store creds so we can re-login on re-run
        set_env_value "N8N_ADMIN_EMAIL" "$N8N_ADMIN_EMAIL"
        set_env_value "N8N_ADMIN_PASSWORD" "$N8N_ADMIN_PASSWORD"
    else
        print_warning "Failed to create n8n owner account"
        print_info "Create account manually: http://${HOST_IP:-localhost}:${N8N_PORT:-5678}"
        return 0 2>/dev/null || exit 0
    fi
elif [[ -z "$N8N_ADMIN_EMAIL" ]] || [[ -z "$N8N_ADMIN_PASSWORD" ]]; then
    # Owner exists but we don't have stored credentials
    print_info "n8n owner already exists but no credentials stored"
    print_info "Create API key manually: n8n Settings → n8n API"
    print_info "Then set ANCROO_N8N_API_KEY in .env and run: ./module.sh setup ancroo"
    return 0 2>/dev/null || exit 0
else
    print_info "n8n owner already configured ($N8N_ADMIN_EMAIL)"
fi

# ─── Step 2: Login to get session cookie ──────────────────
printf '{"emailOrLdapLoginId":"%s","password":"%s"}' \
    "$N8N_ADMIN_EMAIL" "$N8N_ADMIN_PASSWORD" > "$TMPDIR/login.json"

# n8n sets the cookie with Secure flag, so curl's cookie jar won't
# send it back over plain HTTP.  Extract the cookie value from the
# Set-Cookie response header instead.
LOGIN_HEADERS=$(curl -s -D - -X POST "${N8N_URL}/rest/login" \
    -H "Content-Type: application/json" \
    -d @"$TMPDIR/login.json" \
    -o "$TMPDIR/login_body.txt" 2>&1)

LOGIN_RESP=$(cat "$TMPDIR/login_body.txt")

if ! echo "$LOGIN_RESP" | grep -q '"email"'; then
    print_warning "Failed to login to n8n — create API key manually"
    print_info "n8n Settings → n8n API → Create API Key"
    return 0 2>/dev/null || exit 0
fi

AUTH_COOKIE=$(echo "$LOGIN_HEADERS" | grep -oP 'n8n-auth=\K[^;]+' || true)
if [[ -z "$AUTH_COOKIE" ]]; then
    print_warning "Failed to extract n8n session cookie"
    print_info "Create API key manually: n8n Settings → n8n API"
    return 0 2>/dev/null || exit 0
fi

# ─── Step 3: Create API key (10 year expiry) ──────────────
# Delete any existing key with our label first (n8n enforces unique labels)
EXISTING_KEYS=$(curl -s "${N8N_URL}/rest/api-keys" \
    -H "Cookie: n8n-auth=${AUTH_COOKIE}" 2>&1)
EXISTING_ID=$(echo "$EXISTING_KEYS" | python3 -c "
import json, sys
for k in json.load(sys.stdin).get('data', []):
    if k.get('label') == 'ancroo-backend':
        print(k['id']); break
" 2>/dev/null || true)
if [[ -n "$EXISTING_ID" ]]; then
    curl -s -X DELETE "${N8N_URL}/rest/api-keys/${EXISTING_ID}" \
        -H "Cookie: n8n-auth=${AUTH_COOKIE}" >/dev/null 2>&1
fi

# n8n expects expiresAt as Unix timestamp in seconds
EXPIRES_AT=$(( $(date +%s) + 315360000 ))

printf '{"label":"ancroo-backend","scopes":["workflow:create","workflow:read","workflow:update","workflow:delete","workflow:list","workflow:execute"],"expiresAt":%d}' \
    "$EXPIRES_AT" > "$TMPDIR/apikey.json"

APIKEY_RESP=$(curl -s -X POST "${N8N_URL}/rest/api-keys" \
    -H "Content-Type: application/json" \
    -H "Cookie: n8n-auth=${AUTH_COOKIE}" \
    -d @"$TMPDIR/apikey.json" 2>&1)

RAW_KEY=$(echo "$APIKEY_RESP" | grep -o '"rawApiKey":"[^"]*"' | cut -d'"' -f4)

if [[ -z "$RAW_KEY" ]]; then
    print_warning "Failed to create n8n API key — create manually in n8n Settings"
    print_info "n8n Settings → n8n API → Create API Key"
    return 0 2>/dev/null || exit 0
fi

# ─── Step 4: Store API key in .env ────────────────────────
set_env_value "ANCROO_N8N_API_KEY" "$RAW_KEY"
print_success "n8n API key created and stored in .env"

print_info "n8n admin: $N8N_ADMIN_EMAIL"
print_info "Access: http://${HOST_IP:-localhost}:${N8N_PORT:-5678}"
