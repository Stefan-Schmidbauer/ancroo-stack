#!/bin/bash
# BookStack Module — Post-Enable Script
# Updates the default admin user with the credentials from setup.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

source "$PROJECT_ROOT/tools/install/lib/common.sh" 2>/dev/null || {
    print_info() { echo "  -> $1"; }
    print_success() { echo "  OK: $1"; }
    print_warning() { echo "  WARN: $1"; }
    print_step() { echo "==> $1"; }
    safe_source_env() { set -a; source "$1"; set +a; }
}

# Load environment
safe_source_env "$PROJECT_ROOT/.env"

ADMIN_EMAIL="${BOOKSTACK_ADMIN_EMAIL:-admin@admin.com}"
ADMIN_PASSWORD="${BOOKSTACK_ADMIN_PASSWORD:-CHANGE_ME_admin_password}"

# Skip if credentials are still placeholders (setup.sh hasn't run yet)
if [[ "$ADMIN_PASSWORD" == CHANGE_ME* ]] || [[ "$ADMIN_PASSWORD" == "password" ]]; then
    return 0 2>/dev/null || exit 0
fi

# ─── Wait for BookStack to be healthy ─────────────────────
print_step "Configuring BookStack admin user..."

MAX_WAIT=120
WAITED=0
while true; do
    if docker exec bookstack curl -sf http://localhost:80/status >/dev/null 2>&1; then
        break
    fi
    if [[ $WAITED -ge $MAX_WAIT ]]; then
        print_warning "BookStack not ready after ${MAX_WAIT}s — admin setup skipped"
        print_info "Change admin credentials manually in the BookStack UI"
        return 0 2>/dev/null || exit 0
    fi
    sleep 5
    WAITED=$((WAITED + 5))
done

# ─── Update admin user via artisan tinker ─────────────────
# BookStack creates admin@admin.com (ID=1) during migration.
# Update email and password via PHP tinker command.
# Credentials are passed as environment variables to avoid shell/PHP injection.
RESULT=$(docker exec \
    -e "TINKER_EMAIL=$ADMIN_EMAIL" \
    -e "TINKER_PASSWORD=$ADMIN_PASSWORD" \
    bookstack php /app/www/artisan tinker --execute='
$user = \BookStack\Users\Models\User::find(1);
if ($user) {
    $user->email = env("TINKER_EMAIL");
    $user->password = bcrypt(env("TINKER_PASSWORD"));
    $user->save();
    echo "ADMIN_UPDATED";
}
' 2>&1) || {
    print_warning "Admin update failed — use default login"
    return 0 2>/dev/null || exit 0
}

if echo "$RESULT" | grep -q "ADMIN_UPDATED"; then
    print_success "Admin updated: $ADMIN_EMAIL"
else
    print_warning "Could not update admin credentials"
    print_info "Default login: admin@admin.com / password"
fi
