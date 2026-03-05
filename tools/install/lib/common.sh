#!/bin/bash
# common.sh — Shared helper functions for ancroo-stack

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

# Logging
print_header() {
    echo ""
    echo -e "${BOLD}${BLUE}  $1${NC}"
    echo -e "${BLUE}  $(printf '=%.0s' $(seq 1 ${#1}))${NC}"
    echo ""
}

print_success() {
    echo -e "  ${GREEN}✓${NC} $1"
}

print_warning() {
    echo -e "  ${YELLOW}⚠${NC} $1"
}

print_error() {
    echo -e "  ${RED}✗${NC} $1"
}

print_info() {
    echo -e "  ${CYAN}→${NC} $1"
}

print_step() {
    echo -e "\n  ${BOLD}$1${NC}"
}

# User interaction
confirm() {
    local prompt="$1"
    local default="${2:-y}"
    local hint="[Y/n]"
    [[ "$default" == "n" ]] && hint="[y/N]"

    echo -ne "  ${prompt} ${hint}: " >&2
    read -r answer
    answer="${answer:-$default}"
    [[ "$answer" =~ ^[Yy] ]]
}

prompt_input() {
    local prompt="$1"
    local default="$2"
    local is_secret="${3:-false}"
    local result

    if [[ "$is_secret" == "true" ]]; then
        echo -ne "  ${prompt}: " >&2
        read -rs result
        echo "" >&2
    elif [[ -n "$default" ]]; then
        echo -ne "  ${prompt} [${default}]: " >&2
        read -r result
        result="${result:-$default}"
    else
        echo -ne "  ${prompt}: " >&2
        read -r result
    fi

    echo "$result"
}

# Safe .env loader — parses line-by-line without shell interpretation.
# Works with values containing backticks, quotes, and other special chars.
# Compatible with Docker Compose .env format.
safe_source_env() {
    local env_file="${1:-${PROJECT_ROOT:-.}/.env}"
    [[ -f "$env_file" ]] || return 1
    while IFS= read -r line || [[ -n "$line" ]]; do
        [[ -z "$line" || "$line" =~ ^[[:space:]]*# ]] && continue
        local key="${line%%=*}"
        local value="${line#*=}"
        if [[ "$value" =~ ^\"(.*)\"$ ]] || [[ "$value" =~ ^\'(.*)\'$ ]]; then
            value="${BASH_REMATCH[1]}"
        fi
        export "$key=$value"
    done < "$env_file"
}

# Environment file management
# Used by setup scripts (ssl, sso) that run as subprocesses
# and cannot access module.sh's built-in update_env_var()
update_env_var() {
    local key="$1"
    local value="$2"
    local env_file="${3:-${PROJECT_ROOT:-.}/.env}"

    local temp_file
    temp_file=$(mktemp "${env_file}.XXXXXX")

    local found=false
    while IFS= read -r line; do
        if [[ "$line" =~ ^${key}= ]]; then
            echo "${key}=\"${value}\"" >> "$temp_file"
            found=true
        else
            echo "$line" >> "$temp_file"
        fi
    done < "$env_file"

    if ! $found; then
        echo "${key}=\"${value}\"" >> "$temp_file"
    fi

    mv "$temp_file" "$env_file"
    chmod 600 "$env_file"
}

remove_env_var() {
    local key="$1"
    local env_file="${2:-${PROJECT_ROOT:-.}/.env}"

    [[ -f "$env_file" ]] || return 0
    grep -v "^${key}=" "$env_file" > "${env_file}.tmp"
    mv "${env_file}.tmp" "$env_file"
    chmod 600 "$env_file"
}
