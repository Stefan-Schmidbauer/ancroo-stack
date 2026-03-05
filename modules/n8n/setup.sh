#!/bin/bash
# n8n Module Setup — Generates encryption key and API key if not yet configured
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
ENV_FILE="$PROJECT_ROOT/.env"

source "$PROJECT_ROOT/tools/install/lib/common.sh" 2>/dev/null || {
    print_info() { echo "  → $1"; }
    print_success() { echo "  ✓ $1"; }
}

generate_hex_16() {
    openssl rand -hex 16
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

print_info "Generating n8n secrets..."

update_if_placeholder "N8N_ENCRYPTION_KEY" generate_hex_16

print_success "n8n secrets configured"
