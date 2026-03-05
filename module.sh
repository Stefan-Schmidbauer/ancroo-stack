#!/bin/bash
# module.sh — ancroo-stack Module Manager
set -euo pipefail

# ─── Configuration ────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$SCRIPT_DIR"
MODULES_DIR="$PROJECT_ROOT/modules"
ENV_FILE="$PROJECT_ROOT/.env"
LOCK_FILE="$PROJECT_ROOT/.module.lock"
LOG_FILE="$PROJECT_ROOT/logs/module-actions.log"
BACKUP_DIR="$PROJECT_ROOT/logs/backups"

# Global flags
DRY_RUN=false
ENV_LOADED=false

# State for rollback
BACKUP_TIMESTAMP=""

# Load common functions
if [[ -f "$PROJECT_ROOT/tools/install/lib/common.sh" ]]; then
    source "$PROJECT_ROOT/tools/install/lib/common.sh"
else
    # Minimal fallback if common.sh not found
    RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
    CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'
    print_error() { echo -e "  ${RED}✗${NC} $1" >&2; }
    print_success() { echo -e "  ${GREEN}✓${NC} $1"; }
    print_info() { echo -e "  ${CYAN}→${NC} $1"; }
    print_warning() { echo -e "  ${YELLOW}⚠${NC} $1"; }
    print_step() { echo -e "\n  ${BOLD}$1${NC}"; }
fi

# ─── Logging & Audit Trail ────────────────────────────────────
log_action() {
    local action="$1"
    local module="${2:-}"
    local status="${3:-SUCCESS}"
    local details="${4:-}"

    mkdir -p "$(dirname "$LOG_FILE")"
    local timestamp
    timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    echo "[$timestamp] $action | Module: $module | Status: $status | Details: $details" >> "$LOG_FILE"
}

# ─── Lock Management ──────────────────────────────────────────
acquire_lock() {
    local max_wait=30
    local waited=0

    while [[ $waited -lt $max_wait ]]; do
        if mkdir "$LOCK_FILE" 2>/dev/null; then
            # Lock acquired
            echo $$ > "$LOCK_FILE/pid"
            trap release_lock EXIT
            return 0
        fi

        # Check if lock holder is still alive
        if [[ -f "$LOCK_FILE/pid" ]]; then
            local lock_pid
            lock_pid=$(cat "$LOCK_FILE/pid")
            if ! kill -0 "$lock_pid" 2>/dev/null; then
                # Stale lock, remove it
                rm -rf "$LOCK_FILE"
                continue
            fi
        fi

        sleep 1
        waited=$((waited + 1))
    done

    print_error "Konnte Lock nicht erwerben (Timeout). Laeuft bereits ein module.sh?"
    exit 1
}

release_lock() {
    if [[ -d "$LOCK_FILE" ]]; then
        rm -rf "$LOCK_FILE"
    fi
}

# ─── Backup & Rollback ────────────────────────────────────────
create_state_backup() {
    BACKUP_TIMESTAMP=$(date '+%Y%m%d-%H%M%S')
    mkdir -p "$BACKUP_DIR"

    if [[ -f "$ENV_FILE" ]]; then
        cp "$ENV_FILE" "$BACKUP_DIR/.env.$BACKUP_TIMESTAMP"
        log_action "BACKUP" "state" "SUCCESS" "Created .env backup"
    fi

    if $DRY_RUN; then
        print_info "[DRY-RUN] Backup erstellt: .env.$BACKUP_TIMESTAMP"
    fi
}

restore_state_backup() {
    if [[ -z "$BACKUP_TIMESTAMP" ]]; then
        print_warning "Kein Backup vorhanden zum Wiederherstellen"
        return 1
    fi

    local backup_file="$BACKUP_DIR/.env.$BACKUP_TIMESTAMP"
    if [[ -f "$backup_file" ]]; then
        cp "$backup_file" "$ENV_FILE"
        print_warning "State wiederhergestellt aus Backup: $BACKUP_TIMESTAMP"
        log_action "ROLLBACK" "state" "SUCCESS" "Restored from backup $BACKUP_TIMESTAMP"
        return 0
    else
        print_error "Backup nicht gefunden: $backup_file"
        return 1
    fi
}

# ─── Environment Management (Cached + Atomic) ─────────────────
load_env() {
    if $ENV_LOADED; then
        return 0
    fi

    if [[ ! -f "$ENV_FILE" ]]; then
        print_error ".env nicht gefunden. Bitte erst ./install.sh ausfuehren"
        exit 1
    fi

    # Parse .env line-by-line instead of source to handle special characters
    # (backticks, quotes, etc.) the same way Docker Compose does.
    while IFS= read -r line || [[ -n "$line" ]]; do
        # Skip comments and empty lines
        [[ -z "$line" || "$line" =~ ^[[:space:]]*# ]] && continue
        local key="${line%%=*}"
        local value="${line#*=}"
        # Strip surrounding double or single quotes
        if [[ "$value" =~ ^\"(.*)\"$ ]] || [[ "$value" =~ ^\'(.*)\'$ ]]; then
            value="${BASH_REMATCH[1]}"
        fi
        export "$key=$value"
    done < "$ENV_FILE"

    ENV_LOADED=true
}

reload_env() {
    ENV_LOADED=false
    load_env
}

update_env_var() {
    local key="$1"
    local value="$2"

    if $DRY_RUN; then
        print_info "[DRY-RUN] Wuerde .env updaten: ${key}=${value}"
        return 0
    fi

    # Atomic write: create temp file, then move
    local temp_file
    temp_file=$(mktemp)

    local found=false
    while IFS= read -r line; do
        if [[ "$line" =~ ^${key}= ]]; then
            echo "${key}=\"${value}\"" >> "$temp_file"
            found=true
        else
            echo "$line" >> "$temp_file"
        fi
    done < "$ENV_FILE"

    # If key wasn't found, append it
    if ! $found; then
        echo "${key}=\"${value}\"" >> "$temp_file"
    fi

    # Atomic move (preserve ownership for non-root access)
    mv -f "$temp_file" "$ENV_FILE"
    chown "${PUID:-1000}:${DOCKER_GID:-984}" "$ENV_FILE"
    chmod 640 "$ENV_FILE"

    # Force reload on next access
    ENV_LOADED=false
}

# ─── Module Configuration ─────────────────────────────────────
load_module_conf() {
    local module_name="$1"
    local conf_file="$MODULES_DIR/$module_name/module.conf"

    if [[ ! -f "$conf_file" ]]; then
        print_error "Modul '$module_name' nicht gefunden"
        return 1
    fi

    # Reset variables
    MODULE_NAME=""
    MODULE_DESCRIPTION=""
    MODULE_SERVICES=""
    MODULE_DATA_DIRS=""
    MODULE_DEPENDS=""
    MODULE_CONFLICTS=""
    MODULE_GPU_SUPPORT=""
    MODULE_PORT=""
    MODULE_INTERNAL_PORT=""
    MODULE_DOMAIN_VAR=""
    MODULE_DB=""
    MODULE_SSO_TYPE=""
    MODULE_SSO_GROUP=""
    MODULE_EXPERIMENTAL=""

    source "$conf_file"
    return 0
}

is_module_enabled() {
    local module_name="$1"
    load_env
    [[ " $ENABLED_MODULES " =~ " $module_name " ]]
}

# ─── Docker Compose File Management ───────────────────────────
validate_compose_file() {
    local file="$1"
    local full_path="$PROJECT_ROOT/$file"

    if [[ ! -f "$full_path" ]]; then
        print_error "Compose-File nicht gefunden: $file"
        return 1
    fi

    # Optional: Validate syntax (can be slow, so commented out by default)
    # docker compose -f "$full_path" config -q 2>/dev/null || {
    #     print_error "Compose-File hat Syntaxfehler: $file"
    #     return 1
    # }

    return 0
}

add_to_compose_file() {
    local new_files="$1"
    load_env

    # Validate all files first
    for file in ${new_files//:/ }; do
        if ! validate_compose_file "$file"; then
            return 1
        fi
    done

    # Add to COMPOSE_FILE if not already present
    local modified=false
    for file in ${new_files//:/ }; do
        if [[ ! "$COMPOSE_FILE" =~ (^|:)${file}(:|$) ]]; then
            COMPOSE_FILE="${COMPOSE_FILE}:${file}"
            modified=true
        fi
    done

    if $modified; then
        update_env_var "COMPOSE_FILE" "$COMPOSE_FILE"
    fi
}

remove_from_compose_file() {
    local files_to_remove="$1"
    load_env

    local new_compose_file=""
    for file in ${COMPOSE_FILE//:/ }; do
        local should_keep=true
        for remove_file in ${files_to_remove//:/ }; do
            if [[ "$file" == "$remove_file" ]]; then
                should_keep=false
                break
            fi
        done
        if $should_keep; then
            if [[ -z "$new_compose_file" ]]; then
                new_compose_file="$file"
            else
                new_compose_file="${new_compose_file}:${file}"
            fi
        fi
    done

    update_env_var "COMPOSE_FILE" "$new_compose_file"
}

# ─── Module Hook Execution ───────────────────────────────────
# Hooks are sourced (not executed) so they have access to all module.sh functions
run_module_hook() {
    local hook_file="$1"
    local hook_arg="${2:-}"

    [[ ! -f "$hook_file" ]] && return 0

    if $DRY_RUN; then
        print_info "[DRY-RUN] Wuerde Hook ausfuehren: $(basename "$hook_file")"
        return 0
    fi
    source "$hook_file" "$hook_arg"
}

# ─── Reconcile ────────────────────────────────────────────────
# Rebuilds COMPOSE_FILE from scratch based on ENABLED_MODULES, INSTALL_MODE,
# and GPU_MODE. Called after every enable/disable to ensure all overlays
# (mode, GPU, SSO) are correct regardless of enable/disable order.
reconcile_compose() {
    if $DRY_RUN; then
        print_info "[DRY-RUN] Would reconcile COMPOSE_FILE"
        return 0
    fi

    reload_env

    # Base compose
    local cf="docker-compose.yml"

    # Base mode: port mappings for core services
    if [[ "${INSTALL_MODE:-base}" == "base" ]] && [[ -f "$PROJECT_ROOT/docker-compose.ports.yml" ]]; then
        cf="${cf}:docker-compose.ports.yml"
    fi

    # GPU overlay for core services (ollama)
    if [[ "${GPU_MODE:-cpu}" != "cpu" ]] && [[ -f "$MODULES_DIR/gpu-${GPU_MODE}/compose.yml" ]]; then
        cf="${cf}:modules/gpu-${GPU_MODE}/compose.yml"
    fi

    # Module compose files
    local mod
    for mod in $ENABLED_MODULES; do
        [[ "$mod" =~ ^gpu- ]] && continue

        # Base module compose
        [[ -f "$MODULES_DIR/$mod/compose.yml" ]] && cf="${cf}:modules/${mod}/compose.yml"

        # Mode-specific overlay
        if [[ "${INSTALL_MODE:-base}" == "base" ]]; then
            [[ -f "$MODULES_DIR/$mod/compose.ports.yml" ]] && cf="${cf}:modules/${mod}/compose.ports.yml"
        elif [[ "${INSTALL_MODE:-base}" == "ssl" ]]; then
            [[ -f "$MODULES_DIR/$mod/compose.traefik.yml" ]] && cf="${cf}:modules/${mod}/compose.traefik.yml"
        fi

        # GPU overlay for module
        if [[ "${GPU_MODE:-cpu}" != "cpu" ]] && [[ -f "$MODULES_DIR/$mod/compose.${GPU_MODE}.yml" ]]; then
            cf="${cf}:modules/${mod}/compose.${GPU_MODE}.yml"
        fi

        # Local build overlay (dev mode — auto-detected by file presence)
        [[ -f "$MODULES_DIR/$mod/compose.build.yml" ]] && cf="${cf}:modules/${mod}/compose.build.yml"
    done

    # SSO overlays (only when SSO is in ENABLED_MODULES)
    if [[ " $ENABLED_MODULES " =~ " sso " ]]; then
        # Open WebUI OAuth env vars + Keycloak DNS
        [[ -f "$MODULES_DIR/sso/compose.openwebui.yml" ]] && cf="${cf}:modules/sso/compose.openwebui.yml"

        # BookStack Keycloak DNS resolution
        [[ " $ENABLED_MODULES " =~ " bookstack " ]] && [[ -f "$MODULES_DIR/sso/compose.bookstack.yml" ]] \
            && cf="${cf}:modules/sso/compose.bookstack.yml"

        # Traefik + Homepage forward-auth
        [[ " $ENABLED_MODULES " =~ " ssl " ]] && [[ -f "$MODULES_DIR/ssl/compose.sso.yml" ]] \
            && cf="${cf}:modules/ssl/compose.sso.yml"

        # Per-module SSO overlays (proxy modules get forward-auth middleware)
        for mod in $ENABLED_MODULES; do
            [[ "$mod" == "sso" || "$mod" == "ssl" ]] && continue
            [[ "$mod" =~ ^gpu- ]] && continue
            if load_module_conf "$mod" 2>/dev/null && [[ "$MODULE_SSO_TYPE" == "proxy" ]]; then
                [[ -f "$MODULES_DIR/$mod/compose.sso.yml" ]] && cf="${cf}:modules/${mod}/compose.sso.yml"
            fi
        done
    fi

    update_env_var "COMPOSE_FILE" "$cf"
    print_success "COMPOSE_FILE reconciled"
}

# Ensures all enabled modules are registered with Keycloak SSO.
# Idempotent — safe to call after every enable/disable.
reconcile_sso() {
    # Only run if SSO is enabled
    [[ " $ENABLED_MODULES " =~ " sso " ]] || return 0

    # Only run if Keycloak container is running
    if ! docker ps --format '{{.Names}}' | grep -q '^keycloak$'; then
        return 0
    fi

    if $DRY_RUN; then
        print_info "[DRY-RUN] Would reconcile SSO registrations"
        return 0
    fi

    reload_env
    local mod
    for mod in $ENABLED_MODULES; do
        [[ "$mod" == "sso" ]] && continue
        [[ "$mod" =~ ^gpu- ]] && continue
        if load_module_conf "$mod" 2>/dev/null && [[ -n "$MODULE_SSO_TYPE" ]]; then
            bash "$MODULES_DIR/sso/sso-hook.sh" register "$mod" 2>/dev/null || true
        fi
    done
}

# ─── Database Management ─────────────────────────────────────
ensure_module_database() {
    local db_name="$1"

    if $DRY_RUN; then
        print_info "[DRY-RUN] Wuerde Datenbank erstellen: $db_name"
        return 0
    fi

    # Check if postgres container is running
    if ! docker ps --format '{{.Names}}' | grep -q '^postgres$'; then
        print_warning "PostgreSQL laeuft nicht — Datenbank '$db_name' muss manuell erstellt werden"
        return 0
    fi

    load_env
    local pg_user="${POSTGRES_USER:-ancroo}"

    # Create database if it doesn't exist
    local db_exists
    db_exists=$(docker exec postgres psql -U "$pg_user" -tAc "SELECT 1 FROM pg_database WHERE datname='$db_name'" 2>/dev/null || echo "")
    if [[ "$db_exists" != "1" ]]; then
        docker exec postgres psql -U "$pg_user" -c "CREATE DATABASE \"$db_name\" OWNER \"$pg_user\"" 2>/dev/null || {
            print_error "Fehler beim Erstellen der Datenbank: $db_name"
            return 1
        }
        print_success "Datenbank erstellt: $db_name"
    else
        print_info "Datenbank existiert bereits: $db_name"
    fi
}

# ─── Service Management ───────────────────────────────────────
wait_for_service() {
    local service="$1"
    local max_wait="${2:-30}"

    if $DRY_RUN; then
        print_info "[DRY-RUN] Wuerde auf Service warten: $service"
        return 0
    fi

    print_info "Warte auf Service-Start: $service"

    for i in $(seq 1 "$max_wait"); do
        if docker compose ps "$service" 2>/dev/null | grep -q "Up"; then
            return 0
        fi
        sleep 1
    done

    print_error "Service '$service' ist nach ${max_wait}s nicht gestartet"

    # Show logs for debugging
    print_info "Letzte Logs von $service:"
    docker compose logs --tail=20 "$service" 2>/dev/null || true

    return 1
}

start_service() {
    local service="$1"

    if $DRY_RUN; then
        print_info "[DRY-RUN] Wuerde Service starten: $service"
        return 0
    fi

    cd "$PROJECT_ROOT"

    if ! docker compose up -d "$service" 2>&1; then
        print_error "Fehler beim Starten von $service"
        return 1
    fi

    if wait_for_service "$service" 30; then
        print_success "$service gestartet"
        return 0
    else
        return 1
    fi
}

stop_service() {
    local service="$1"

    if $DRY_RUN; then
        print_info "[DRY-RUN] Wuerde Service stoppen: $service"
        return 0
    fi

    cd "$PROJECT_ROOT"

    docker compose stop "$service" 2>/dev/null || true
    docker compose rm -f "$service" 2>/dev/null || true
    print_success "$service gestoppt"
}

# ─── Module Environment Variables ─────────────────────────────
add_module_env_vars() {
    local module_name="$1"
    local module_env_file="$MODULES_DIR/$module_name/module.env"

    if [[ ! -f "$module_env_file" ]]; then
        return 0
    fi

    # Read module.env and add missing variables to .env
    while IFS= read -r line; do
        # Skip empty lines and comments
        [[ -z "$line" || "$line" =~ ^[[:space:]]*# ]] && continue

        # Extract key=value
        if [[ "$line" =~ ^([^=]+)=(.*)$ ]]; then
            local key="${BASH_REMATCH[1]}"
            local value="${BASH_REMATCH[2]}"

            # Only add if not already present in .env file
            if ! grep -q "^${key}=" "$ENV_FILE"; then
                # If the variable is already set in the shell environment
                # (e.g. exported by a parent installer), use that value
                # instead of the module.env default.
                if [[ -n "${!key+x}" ]]; then
                    value="${!key}"
                fi
                if $DRY_RUN; then
                    print_info "[DRY-RUN] Wuerde ENV-Variable hinzufuegen: ${key}=${value}"
                else
                    echo "${key}=\"${value}\"" >> "$ENV_FILE"
                    print_info "ENV-Variable hinzugefuegt: ${key}=${value}"
                fi
            fi
        fi
    done < "$module_env_file"

    if ! $DRY_RUN; then
        ENV_LOADED=false  # Force reload
    fi
}

# ─── Domain Management ────────────────────────────────────────
# Updates a module's domain variable to use BASE_DOMAIN and its APP_URL if present.
update_module_domain() {
    local module_name="$1"
    local domain_var="$2"

    reload_env
    local current_domain="${!domain_var:-}"
    if [[ -z "$current_domain" ]] || [[ -z "${BASE_DOMAIN:-}" ]]; then
        return 0
    fi

    local domain_prefix="${current_domain%%.*}"
    local new_domain="${domain_prefix}.${BASE_DOMAIN}"
    update_env_var "$domain_var" "$new_domain"
    print_info "Domain aktualisiert: ${domain_var}=${new_domain}"

    # Update APP_URL if present (e.g. BOOKSTACK_APP_URL)
    local upper_mod
    upper_mod=$(echo "$module_name" | tr '[:lower:]-' '[:upper:]_')
    local app_url_var="${upper_mod}_APP_URL"
    if grep -q "^${app_url_var}=" "$ENV_FILE" 2>/dev/null; then
        update_env_var "$app_url_var" "https://${new_domain}"
        print_info "App-URL aktualisiert: ${app_url_var}=https://${new_domain}"
    fi
}

# ─── Homepage Dashboard ───────────────────────────────────────
update_homepage_config() {
    local homepage_config_dir="$PROJECT_ROOT/data/homepage"
    local services_file="$homepage_config_dir/services.yaml"

    if $DRY_RUN; then
        print_info "[DRY-RUN] Wuerde Homepage-Dashboard aktualisieren"
        return 0
    fi

    mkdir -p "$homepage_config_dir"

    # Backup if file exists and wasn't auto-generated
    if [[ -f "$services_file" ]] && ! grep -q "Auto-generated by module.sh" "$services_file" 2>/dev/null; then
        local backup_file="$services_file.manual.$(date '+%Y%m%d-%H%M%S').backup"
        cp "$services_file" "$backup_file"
        print_warning "Manuelle services.yaml gesichert: $(basename "$backup_file")"
    fi

    # Export env vars for envsubst
    load_env
    export HOST_IP="${HOST_IP:-localhost}"

    # Load all module.env files for variable defaults
    for module in $ENABLED_MODULES; do
        local module_env_file="$MODULES_DIR/$module/module.env"
        if [[ -f "$module_env_file" ]]; then
            while IFS='=' read -r key value; do
                [[ "$key" =~ ^#.*$ || -z "$key" ]] && continue
                value="${value%\"}"
                value="${value#\"}"
                if [[ -z "${!key:-}" ]]; then
                    export "$key=$value"
                fi
            done < "$module_env_file"
        fi
    done

    local temp_file
    temp_file=$(mktemp)

    # Create header
    cat > "$temp_file" << 'EOF'
# ancroo-stack — Homepage Dashboard Services
# Auto-generated by module.sh — Do not edit manually
---
EOF

    # Choose template based on install mode (SSL uses domain-based URLs)
    local template_name="homepage.yml"
    if [[ "${INSTALL_MODE:-base}" == "ssl" ]]; then
        template_name="homepage.ssl.yml"
    fi

    # Always include core services first
    local core_snippet="$PROJECT_ROOT/tools/config/homepage/${template_name}"
    [[ ! -f "$core_snippet" ]] && core_snippet="$PROJECT_ROOT/tools/config/homepage/homepage.yml"
    if [[ -f "$core_snippet" ]]; then
        grep -v '^#' "$core_snippet" | envsubst >> "$temp_file"
    fi

    # Merge all enabled module homepage files
    for module in $ENABLED_MODULES; do
        local homepage_yml="$MODULES_DIR/$module/${template_name}"
        [[ ! -f "$homepage_yml" ]] && homepage_yml="$MODULES_DIR/$module/homepage.yml"
        if [[ -f "$homepage_yml" ]]; then
            echo "" >> "$temp_file"
            grep -v '^#' "$homepage_yml" | envsubst >> "$temp_file"
        fi
    done

    # Merge duplicate YAML groups (e.g. multiple modules sharing "Speech" group)
    python3 -c "
import sys, re
lines = open(sys.argv[1]).readlines()
header, groups, order = [], {}, []
current, body = None, []
for line in lines:
    m = re.match(r'^- (.+):\s*$', line)
    if m:
        if current is not None:
            groups.setdefault(current, []).extend(body)
            if current not in [g for g in order]: order.append(current)
        current, body = m.group(1), []
    elif current is not None:
        body.append(line)
    else:
        header.append(line)
if current is not None:
    groups.setdefault(current, []).extend(body)
    if current not in order: order.append(current)
with open(sys.argv[1], 'w') as f:
    f.writelines(header)
    for g in order:
        f.write(f'- {g}:\n')
        content = ''.join(groups[g]).strip('\n')
        if content: f.write(content + '\n')
        f.write('\n')
" "$temp_file"

    mv -f "$temp_file" "$services_file"
    chown "${PUID:-1000}:${DOCKER_GID:-984}" "$services_file"
    chmod 644 "$services_file"
    print_success "Homepage-Dashboard aktualisiert"
}

# ─── Dependency Resolution ────────────────────────────────────
check_circular_dependency() {
    local module_name="$1"
    local visited="${2:-}"

    if [[ " $visited " =~ " $module_name " ]]; then
        print_error "Zirkulaere Abhaengigkeit erkannt: $visited -> $module_name"
        log_action "ENABLE" "$module_name" "ERROR" "Circular dependency: $visited"
        return 1
    fi

    return 0
}

enable_dependencies() {
    local module_name="$1"
    local visited="${2:-}"

    if ! load_module_conf "$module_name"; then
        return 1
    fi

    if [[ -z "$MODULE_DEPENDS" ]]; then
        return 0
    fi

    for dep in $MODULE_DEPENDS; do
        if ! is_module_enabled "$dep"; then
            print_info "Aktiviere Abhaengigkeit: $dep"
            if ! cmd_enable_internal "$dep" "$visited $module_name"; then
                print_error "Fehler beim Aktivieren der Abhaengigkeit: $dep"
                return 1
            fi
        fi
    done

    return 0
}

# ─── SSO/SSL Integration ─────────────────────────────────────
## Handled by reconcile_compose() and reconcile_sso() after every enable/disable.
## No cross-module hooks needed — reconcile rebuilds state from scratch.

# ─── Commands ─────────────────────────────────────────────────
cmd_list() {
    echo ""
    echo -e "  ${BOLD}Verfuegbare Module:${NC}"
    echo ""

    load_env

    for module_dir in "$MODULES_DIR"/*; do
        if [[ ! -d "$module_dir" ]]; then
            continue
        fi

        local module_name
        module_name=$(basename "$module_dir")

        # Skip implicit modules (gpu-*)
        if [[ "$module_name" =~ ^gpu- ]]; then
            continue
        fi

        if ! load_module_conf "$module_name"; then
            continue
        fi

        local status="  "
        if is_module_enabled "$module_name"; then
            status="${GREEN}✓${NC}"
        else
            status=" "
        fi

        local desc="$MODULE_DESCRIPTION"
        if [[ "$MODULE_EXPERIMENTAL" == "true" ]]; then
            desc="${desc} ${YELLOW}(experimental)${NC}"
        fi

        printf "  ${status}  ${BOLD}%-20s${NC} %b\n" "$module_name" "$desc"
    done

    echo ""
}

cmd_status() {
    echo ""
    echo -e "  ${BOLD}Aktivierte Module:${NC}"
    echo ""

    load_env

    local has_modules=false
    for module in $ENABLED_MODULES; do
        # Skip implicit modules (gpu-*)
        if [[ "$module" =~ ^gpu- ]]; then
            continue
        fi

        if load_module_conf "$module"; then
            printf "  ${GREEN}✓${NC}  ${BOLD}%-20s${NC} %s\n" "$module" "$MODULE_DESCRIPTION"
            has_modules=true
        fi
    done

    if ! $has_modules; then
        print_info "Keine Module aktiv"
    fi

    echo ""
    echo -e "  Install-Modus: ${BOLD}${INSTALL_MODE}${NC}"
    echo -e "  GPU-Modus:     ${BOLD}${GPU_MODE}${NC}"
    echo ""
    echo -e "  Tipp: ${CYAN}./module.sh urls${NC} zeigt alle Service-URLs"
    echo ""
}

cmd_verify() {
    load_env

    _VRF_PASSED=0
    _VRF_FAILED=0

    local host="${HOST_IP:-localhost}"
    local docker_info
    docker_info=$(docker ps --format '{{.Names}}|{{.Status}}' 2>/dev/null || echo "")

    print_header "Stack Verification"

    echo -e "  ${BOLD}Containers:${NC}"
    echo ""
    _verify_container "postgres"    "postgres"   "$docker_info"
    _verify_container "Ollama"      "ollama"     "$docker_info"
    _verify_container "Open WebUI"  "open-webui" "$docker_info"
    _verify_container "Homepage"    "homepage"   "$docker_info"

    for module in $ENABLED_MODULES; do
        [[ "$module" =~ ^gpu- ]] && continue
        if load_module_conf "$module" 2>/dev/null; then
            [[ -z "$MODULE_SERVICES" ]] && continue
            local container="${MODULE_SERVICES%% *}"
            _verify_container "$MODULE_NAME" "$container" "$docker_info"
        fi
    done

    echo ""
    echo -e "  ${BOLD}HTTP Health Checks:${NC}"
    echo ""

    if [[ "${INSTALL_MODE:-base}" == "ssl" ]]; then
        _verify_http "Homepage"   "https://${HOMEPAGE_DOMAIN:-${BASE_DOMAIN:-localhost}}"
        _verify_http "Open WebUI" "https://${OPENWEBUI_DOMAIN:-webui.localhost}"
        _verify_http "Ollama API" "https://${OLLAMA_DOMAIN:-ollama.localhost}/api/tags"
    else
        _verify_http "Homepage"   "http://${host}"
        _verify_http "Open WebUI" "http://${host}:8080"
        _verify_http "Ollama API" "http://${host}:11434/api/tags"
    fi

    for module in $ENABLED_MODULES; do
        [[ "$module" =~ ^gpu- ]] && continue
        [[ "$module" == "ssl" ]] && continue
        if load_module_conf "$module" 2>/dev/null; then
            [[ -z "$MODULE_PORT" ]] && continue
            local url
            if [[ "${INSTALL_MODE:-base}" == "ssl" ]] && [[ -n "$MODULE_DOMAIN_VAR" ]]; then
                local domain_value="${!MODULE_DOMAIN_VAR:-}"
                [[ -z "$domain_value" ]] && continue
                url="https://${domain_value}"
            else
                url="http://${host}:${MODULE_PORT}"
            fi
            _verify_http "$MODULE_NAME" "$url"
        fi
    done

    echo ""
    local total=$((_VRF_PASSED + _VRF_FAILED))
    if [[ $_VRF_FAILED -eq 0 ]]; then
        print_success "All checks passed ($_VRF_PASSED/$total)"
    else
        print_error "$_VRF_FAILED check(s) failed ($_VRF_PASSED/$total passed)"
    fi
    echo ""

    return $((_VRF_FAILED > 0 ? 1 : 0))
}

cmd_urls() {
    load_env
    local hosts_ip="${1:-}"

    # /etc/hosts output mode
    if [[ -n "$hosts_ip" ]]; then
        if [[ "${INSTALL_MODE:-base}" != "ssl" ]]; then
            print_error "/etc/hosts output requires SSL mode (domains needed)"
            exit 1
        fi
        echo ""
        echo -e "  ${BOLD}/etc/hosts entries (copy & paste):${NC}"
        echo ""

        # Core services
        printf "%s %s # %s\n" "$hosts_ip" "${HOMEPAGE_DOMAIN:-${BASE_DOMAIN:-localhost}}" "Homepage"
        printf "%s %s # %s\n" "$hosts_ip" "${OPENWEBUI_DOMAIN:-webui.localhost}" "Open WebUI"
        printf "%s %s # %s\n" "$hosts_ip" "${OLLAMA_DOMAIN:-ollama.localhost}" "Ollama API"

        # Enabled modules
        for module in $ENABLED_MODULES; do
            [[ "$module" =~ ^gpu- ]] && continue
            if load_module_conf "$module" 2>/dev/null; then
                [[ -z "$MODULE_DOMAIN_VAR" ]] && continue
                [[ "$module" == "ssl" ]] && continue
                local domain_value="${!MODULE_DOMAIN_VAR:-}"
                if [[ -n "$domain_value" ]]; then
                    printf "%s %s # %s\n" "$hosts_ip" "$domain_value" "$MODULE_NAME"
                fi
            fi
        done

        # Traefik
        if [[ -n "${TRAEFIK_DOMAIN:-}" ]]; then
            printf "%s %s # %s\n" "$hosts_ip" "$TRAEFIK_DOMAIN" "Traefik"
        fi

        echo ""
        return
    fi

    # Normal URL display mode
    echo ""
    echo -e "  ${BOLD}Service-URLs:${NC}"
    echo ""

    # Core services (always present)
    if [[ "${INSTALL_MODE:-base}" == "ssl" ]]; then
        printf "  ${GREEN}✓${NC}  %-20s ${CYAN}https://%s${NC}\n" "Homepage" "${HOMEPAGE_DOMAIN:-${BASE_DOMAIN:-localhost}}"
        printf "  ${GREEN}✓${NC}  %-20s ${CYAN}https://%s${NC}\n" "Open WebUI" "${OPENWEBUI_DOMAIN:-webui.localhost}"
        printf "  ${GREEN}✓${NC}  %-20s ${CYAN}https://%s${NC}\n" "Ollama API" "${OLLAMA_DOMAIN:-ollama.localhost}"
    else
        printf "  ${GREEN}✓${NC}  %-20s ${CYAN}http://%s${NC}\n" "Homepage" "${HOST_IP:-localhost}"
        printf "  ${GREEN}✓${NC}  %-20s ${CYAN}http://%s:8080${NC}\n" "Open WebUI" "${HOST_IP:-localhost}"
        printf "  ${GREEN}✓${NC}  %-20s ${CYAN}http://%s:11434${NC}\n" "Ollama API" "${HOST_IP:-localhost}"
    fi

    # Enabled modules with ports/domains
    for module in $ENABLED_MODULES; do
        [[ "$module" =~ ^gpu- ]] && continue
        if load_module_conf "$module" 2>/dev/null; then
            # Skip modules without web access
            [[ -z "$MODULE_PORT" ]] && [[ -z "$MODULE_DOMAIN_VAR" ]] && continue
            # Skip ssl module (Traefik shown separately)
            [[ "$module" == "ssl" ]] && continue

            if [[ "${INSTALL_MODE:-base}" == "ssl" ]] && [[ -n "$MODULE_DOMAIN_VAR" ]]; then
                local domain_value="${!MODULE_DOMAIN_VAR:-}"
                if [[ -n "$domain_value" ]]; then
                    printf "  ${GREEN}✓${NC}  %-20s ${CYAN}https://%s${NC}\n" "$MODULE_NAME" "$domain_value"
                fi
            elif [[ -n "$MODULE_PORT" ]] && [[ -n "${HOST_IP:-}" ]]; then
                printf "  ${GREEN}✓${NC}  %-20s ${CYAN}http://%s:%s${NC}\n" "$MODULE_NAME" "$HOST_IP" "$MODULE_PORT"
            fi
        fi
    done

    # Traefik (only in SSL mode)
    if [[ "${INSTALL_MODE:-base}" == "ssl" ]] && [[ -n "${TRAEFIK_DOMAIN:-}" ]]; then
        printf "  ${GREEN}✓${NC}  %-20s ${CYAN}https://%s${NC}\n" "Traefik" "$TRAEFIK_DOMAIN"
    fi

    echo ""
    echo -e "  Install-Modus: ${BOLD}${INSTALL_MODE:-base}${NC}"
    if [[ "${INSTALL_MODE:-base}" == "ssl" ]] && [[ -n "${BASE_DOMAIN:-}" ]]; then
        echo -e "  Base-Domain:   ${BOLD}${BASE_DOMAIN}${NC}"
    fi
    echo ""
}

cmd_ports() {
    load_env
    echo ""
    echo -e "  ${BOLD}Module Ports:${NC}"
    echo ""

    # Fetch all running container info in one call
    local docker_info
    docker_info=$(docker ps --format '{{.Names}}|{{.Ports}}|{{.Status}}' 2>/dev/null || echo "")

    local host="${HOST_IP:-localhost}"
    local scheme="http"
    [[ "${INSTALL_MODE:-base}" == "ssl" ]] && scheme="https"

    # Core services (when in base mode with port mappings)
    if [[ "${INSTALL_MODE:-base}" == "base" ]]; then
        _port_line "$docker_info" "Ollama"     "11434" "ollama"     "$scheme" "$host" ""
        _port_line "$docker_info" "Open WebUI" "8080"  "open-webui" "$scheme" "$host" "${OPENWEBUI_DOMAIN:-}"
        _port_line "$docker_info" "Homepage"   "80"    "homepage"   "$scheme" "$host" "${HOMEPAGE_DOMAIN:-}"
    fi

    # Enabled module services
    for module in $ENABLED_MODULES; do
        # Skip implicit modules (gpu-*)
        [[ "$module" =~ ^gpu- ]] && continue

        if ! load_module_conf "$module" 2>/dev/null; then
            continue
        fi

        # Skip modules without ports
        [[ -z "$MODULE_PORT" ]] && continue

        # Derive port env var name: ancroo → ANCROO_PORT, whisper-server → WHISPER_SERVER_PORT
        local port_var
        port_var="$(echo "$module" | tr '[:lower:]-' '[:upper:]_')_PORT"
        local configured_port="${!port_var:-$MODULE_PORT}"

        # Get domain if available
        local domain=""
        if [[ -n "$MODULE_DOMAIN_VAR" ]]; then
            domain="${!MODULE_DOMAIN_VAR:-}"
        fi

        # Use first service as container name
        local container="${MODULE_SERVICES%% *}"

        _port_line "$docker_info" "$MODULE_NAME" "$configured_port" "$container" "$scheme" "$host" "$domain"
    done

    echo ""
}

_port_line() {
    local docker_info="$1"
    local name="$2"
    local port="$3"
    local container="$4"
    local scheme="$5"
    local host="$6"
    local domain="$7"

    local icon="${RED}✗${NC}"
    local status_text="stopped"

    local container_line
    container_line=$(echo "$docker_info" | grep "^${container}|" || echo "")

    if [[ -n "$container_line" ]]; then
        local container_status
        container_status="${container_line##*|}"

        if [[ "$container_status" == *"(healthy)"* ]]; then
            icon="${GREEN}✓${NC}"
            status_text="healthy"
        elif [[ "$container_status" == *"Up"* ]]; then
            icon="${YELLOW}~${NC}"
            status_text="running"
        fi
    fi

    # Build URL: SSL mode with domain → https://domain, otherwise http://host:port
    local url
    if [[ "$scheme" == "https" ]] && [[ -n "$domain" ]]; then
        url="https://${domain}"
    elif [[ "$port" == "80" ]]; then
        url="${scheme}://${host}"
    else
        url="${scheme}://${host}:${port}"
    fi

    printf "  ${icon} %-20s %-10s ${CYAN}%s${NC}\n" "$name" "$status_text" "$url"
}

cmd_containers() {
    load_env
    echo ""
    echo -e "  ${BOLD}Internal Docker addresses (ai-network):${NC}"
    echo ""

    # Fetch all running container info in one call
    local docker_info
    docker_info=$(docker ps --format '{{.Names}}|{{.Status}}' 2>/dev/null || echo "")

    echo -e "  ${BOLD}Core Services:${NC}"
    echo ""
    _container_line "$docker_info" "postgres"   "postgres"   "postgres:5432"
    _container_line "$docker_info" "Ollama"     "ollama"     "http://ollama:11434"
    _container_line "$docker_info" "Open WebUI" "open-webui" "http://open-webui:8080"
    _container_line "$docker_info" "Homepage"   "homepage"   "http://homepage:3000"

    echo ""
    echo -e "  ${BOLD}Modules:${NC}"
    echo ""

    local has_modules=false
    for module in $ENABLED_MODULES; do
        [[ "$module" =~ ^gpu- ]] && continue
        if ! load_module_conf "$module" 2>/dev/null; then
            continue
        fi
        [[ -z "$MODULE_INTERNAL_PORT" ]] && continue

        local container="${MODULE_SERVICES%% *}"
        local addr="http://${container}:${MODULE_INTERNAL_PORT}"

        _container_line "$docker_info" "$MODULE_NAME" "$container" "$addr"
        has_modules=true
    done

    if ! $has_modules; then
        print_info "No modules with internal ports active"
    fi

    echo ""
    echo -e "  Use these addresses for container-to-container communication on ai-network."
    echo ""
}

_verify_container() {
    local label="$1"
    local container="$2"
    local docker_info="$3"

    local line
    line=$(echo "$docker_info" | grep "^${container}|" || echo "")
    if [[ -n "$line" ]]; then
        local cstatus="${line##*|}"
        if [[ "$cstatus" == *"(healthy)"* ]]; then
            printf "  ${GREEN}✓${NC}  %-25s healthy\n" "$label"
        else
            printf "  ${YELLOW}~${NC}  %-25s running (not yet healthy)\n" "$label"
        fi
        _VRF_PASSED=$((_VRF_PASSED + 1))
    else
        printf "  ${RED}✗${NC}  %-25s not running\n" "$label"
        _VRF_FAILED=$((_VRF_FAILED + 1))
    fi
}

_verify_http() {
    local label="$1"
    local url="$2"
    local code
    code=$(curl -sf -o /dev/null -w "%{http_code}" --max-time 5 "$url" 2>/dev/null || echo "000")
    if [[ "$code" =~ ^[23] ]]; then
        printf "  ${GREEN}✓${NC}  %-25s HTTP %s\n" "$label" "$code"
        _VRF_PASSED=$((_VRF_PASSED + 1))
    else
        printf "  ${RED}✗${NC}  %-25s HTTP %s (unreachable)\n" "$label" "$code"
        _VRF_FAILED=$((_VRF_FAILED + 1))
    fi
}

_container_line() {
    local docker_info="$1"
    local name="$2"
    local container="$3"
    local addr="$4"

    local icon="${RED}✗${NC}"
    local status_text="stopped"

    local container_line
    container_line=$(echo "$docker_info" | grep "^${container}|" || echo "")

    if [[ -n "$container_line" ]]; then
        local container_status="${container_line##*|}"
        if [[ "$container_status" == *"(healthy)"* ]]; then
            icon="${GREEN}✓${NC}"
            status_text="healthy"
        elif [[ "$container_status" == *"Up"* ]]; then
            icon="${YELLOW}~${NC}"
            status_text="running"
        fi
    fi

    printf "  ${icon} %-20s %-10s ${CYAN}%s${NC}\n" "$name" "$status_text" "$addr"
}

cmd_setup() {
    local module_name="$1"

    if ! load_module_conf "$module_name"; then
        exit 1
    fi

    local setup_script="$MODULES_DIR/$module_name/setup.sh"
    if [[ ! -f "$setup_script" ]]; then
        print_info "Modul '$module_name' hat kein Setup-Script"
        return 0
    fi

    print_header "${MODULE_NAME} — Setup"
    if ! bash "$setup_script"; then
        print_error "Setup-Script fehlgeschlagen"
        return 1
    fi

    # Reload .env since setup.sh may have modified it
    ENV_LOADED=false
    reload_env
    print_success "Setup abgeschlossen"
}

cmd_info() {
    local module_name="$1"

    if ! load_module_conf "$module_name"; then
        exit 1
    fi

    echo ""
    echo -e "  ${BOLD}Modul: ${MODULE_NAME}${NC}"
    echo -e "  ${MODULE_DESCRIPTION}"
    echo ""

    if [[ -n "$MODULE_SERVICES" ]]; then
        echo "  Services:      ${MODULE_SERVICES}"
    fi

    if [[ -n "$MODULE_DEPENDS" ]]; then
        echo "  Abhaengig von: ${MODULE_DEPENDS}"
    fi

    if [[ -n "$MODULE_CONFLICTS" ]]; then
        echo "  Konflikt mit:  ${MODULE_CONFLICTS}"
    fi

    if [[ -n "$MODULE_GPU_SUPPORT" ]]; then
        echo "  GPU-Support:   ${MODULE_GPU_SUPPORT}"
    fi

    if [[ -n "$MODULE_PORT" ]]; then
        echo "  Port:          ${MODULE_PORT}"
    fi

    # Check enabled status (only if .env exists)
    if [[ -f "$ENV_FILE" ]]; then
        local enabled="Nein"
        if is_module_enabled "$module_name"; then
            enabled="${GREEN}Ja${NC}"
        fi
        echo -e "  Aktiviert:     ${enabled}"
    fi

    echo ""
}

cmd_gpu() {
    local new_mode="${1:-}"

    load_env

    # No argument: show current GPU mode
    if [[ -z "$new_mode" ]]; then
        echo ""
        echo -e "  GPU-Modus: ${BOLD}${GPU_MODE:-cpu}${NC}"
        echo ""
        echo "  Verwendung: $0 gpu <cpu|nvidia|rocm>"
        echo ""
        return 0
    fi

    # Validate mode
    case "$new_mode" in
        cpu|nvidia|rocm) ;;
        *)
            print_error "Ungueltiger GPU-Modus: $new_mode (erlaubt: cpu, nvidia, rocm)"
            return 1
            ;;
    esac

    # Validate GPU compose file exists (for non-cpu)
    if [[ "$new_mode" != "cpu" ]] && [[ ! -f "$MODULES_DIR/gpu-${new_mode}/compose.yml" ]]; then
        print_error "GPU-Modul nicht gefunden: modules/gpu-${new_mode}/compose.yml"
        return 1
    fi

    local old_mode="${GPU_MODE:-cpu}"

    if [[ "$old_mode" == "$new_mode" ]]; then
        print_info "GPU-Modus ist bereits: $new_mode"
        return 0
    fi

    # Check for incompatible enabled modules
    for mod in $ENABLED_MODULES; do
        [[ "$mod" =~ ^gpu- ]] && continue
        if load_module_conf "$mod" 2>/dev/null && [[ -n "$MODULE_GPU_SUPPORT" ]] && [[ "$MODULE_GPU_SUPPORT" != "all" ]]; then
            if [[ ! " $MODULE_GPU_SUPPORT " =~ " $new_mode " ]]; then
                print_error "Modul '$mod' erfordert GPU: $MODULE_GPU_SUPPORT (nicht kompatibel mit $new_mode)"
                print_info "Bitte erst './module.sh disable $mod' ausfuehren"
                return 1
            fi
        fi
    done

    print_step "GPU-Modus wechseln: $old_mode → $new_mode"

    # Update GPU_MODE in .env
    update_env_var "GPU_MODE" "$new_mode"

    # Update ENABLED_MODULES: remove old gpu-*, add new gpu-*
    local new_modules=""
    for mod in $ENABLED_MODULES; do
        [[ "$mod" =~ ^gpu- ]] && continue
        new_modules+="${new_modules:+ }$mod"
    done
    if [[ "$new_mode" != "cpu" ]]; then
        new_modules="gpu-${new_mode}${new_modules:+ $new_modules}"
    fi
    update_env_var "ENABLED_MODULES" "$new_modules"

    # Reconcile COMPOSE_FILE
    reconcile_compose

    # Restart core services to apply GPU change
    print_step "Container neu starten..."
    cd "$PROJECT_ROOT"
    docker compose up -d

    log_action "GPU" "$new_mode" "SUCCESS" "Changed from $old_mode to $new_mode"
    print_success "GPU-Modus gewechselt: $old_mode → $new_mode"
}

prepare_module_resources() {
    local module_name="$1"

    # Create data directories
    if [[ -n "$MODULE_DATA_DIRS" ]]; then
        for dir in $MODULE_DATA_DIRS; do
            if $DRY_RUN; then
                print_info "[DRY-RUN] Wuerde Verzeichnis erstellen: $dir"
            else
                mkdir -p "$PROJECT_ROOT/$dir"
                chown "${PUID:-1000}:${PUID:-1000}" "$PROJECT_ROOT/$dir"
            fi
        done
        if ! $DRY_RUN; then
            print_success "Datenverzeichnisse erstellt"
        fi
    fi

    # Add module environment variables
    add_module_env_vars "$module_name"

    # Update domain variable for non-SSL modules in SSL mode (before setup.sh)
    reload_env
    if [[ "$module_name" != "ssl" ]] && [[ "${INSTALL_MODE:-base}" == "ssl" ]] && [[ -n "$MODULE_DOMAIN_VAR" ]]; then
        update_module_domain "$module_name" "$MODULE_DOMAIN_VAR"
    fi

    # Run module setup script if present (interactive configuration)
    local setup_script="$MODULES_DIR/$module_name/setup.sh"
    if [[ -f "$setup_script" ]]; then
        print_step "Modul-Setup ausfuehren"
        if ! bash "$setup_script"; then
            print_error "Setup-Script fehlgeschlagen"
            log_action "ENABLE" "$module_name" "ERROR" "Setup script failed"
            return 1
        fi
        ENV_LOADED=false
    fi

    return 0
}

handle_ssl_mode_switch() {
    reload_env
    update_env_var "INSTALL_MODE" "ssl"

    # Update domain variables for all already-enabled modules
    if [[ -n "${BASE_DOMAIN:-}" ]]; then
        for mod in $ENABLED_MODULES; do
            [[ "$mod" =~ ^gpu- ]] && continue
            if load_module_conf "$mod" 2>/dev/null && [[ -n "$MODULE_DOMAIN_VAR" ]]; then
                update_module_domain "$mod" "$MODULE_DOMAIN_VAR"
            fi
        done
    fi

    # Stop all services to release port bindings before mode switch
    if ! $DRY_RUN; then
        print_info "Stopping services for SSL mode switch..."
        cd "$PROJECT_ROOT"
        if ! docker compose down 2>&1; then
            print_warning "docker compose down returned an error (continuing with mode switch)"
        fi
    fi
}

start_module_services() {
    local module_name="$1"
    local services="$2"

    print_step "Services starten"

    if ! $DRY_RUN; then
        cd "$PROJECT_ROOT"
        if ! docker compose up -d 2>&1; then
            print_warning "docker compose up returned an error (some services may still have started)"
        fi
    fi

    local failed_services=""
    for service in $services; do
        if $DRY_RUN; then
            print_info "[DRY-RUN] Wuerde auf Service warten: $service"
        elif ! wait_for_service "$service" 30; then
            failed_services="${failed_services} ${service}"
        fi
    done

    if [[ -n "$failed_services" ]]; then
        print_error "Fehler beim Starten von Services:${failed_services}"
        log_action "ENABLE" "$module_name" "ERROR" "Failed to start services:${failed_services}"
        return 1
    fi

    # In SSL mode, restart Traefik so it picks up labels from newly created containers
    if ! $DRY_RUN && [[ "${INSTALL_MODE:-base}" == "ssl" ]]; then
        if docker ps --format '{{.Names}}' | grep -q '^traefik$'; then
            docker restart traefik 2>/dev/null || true
            print_info "Traefik restarted (label discovery)"
        fi
    fi

    return 0
}

show_enable_result() {
    local module_name="$1"

    echo ""
    echo -e "  ${BOLD}Module enabled!${NC}"

    load_module_conf "$module_name"
    reload_env
    if [[ "${INSTALL_MODE:-base}" == "base" ]]; then
        if [[ -n "$MODULE_PORT" ]] && [[ -n "${HOST_IP:-}" ]]; then
            echo -e "  Access: ${CYAN}http://${HOST_IP}:${MODULE_PORT}${NC}"
        fi
    elif [[ "${INSTALL_MODE:-base}" == "ssl" ]]; then
        if [[ -n "$MODULE_DOMAIN_VAR" ]]; then
            local domain_value="${!MODULE_DOMAIN_VAR:-}"
            if [[ -n "$domain_value" ]]; then
                echo -e "  Access: ${CYAN}https://${domain_value}${NC}"
                echo ""
                echo -e "  ${YELLOW}DNS required:${NC} If the domain does not resolve, add hosts entries:"
                echo -e "  ${CYAN}./module.sh urls <HOST_IP>${NC}"
            fi
        fi
    fi

    echo ""
    echo "  All service URLs:  ./module.sh urls"
    echo ""
}

cmd_enable_internal() {
    local module_name="$1"
    local visited="${2:-}"

    # Check circular dependencies
    if ! check_circular_dependency "$module_name" "$visited"; then
        return 1
    fi

    # Check if already enabled
    if is_module_enabled "$module_name"; then
        if [[ -z "$visited" ]]; then
            print_warning "Modul '$module_name' ist bereits aktiviert"
        fi
        return 0
    fi

    # Load module configuration
    if ! load_module_conf "$module_name"; then
        return 1
    fi

    if [[ -z "$visited" ]]; then
        print_header "Modul aktivieren: ${MODULE_NAME}"
        if [[ "$MODULE_EXPERIMENTAL" == "true" ]]; then
            print_warning "Dieses Modul ist experimentell und moeglicherweise unvollstaendig."
        fi
    fi

    # Enable dependencies first
    if ! enable_dependencies "$module_name" "$visited"; then
        return 1
    fi

    # Reload module conf — dependencies may have overwritten global MODULE_* vars
    load_module_conf "$module_name"

    # Check conflicts
    if [[ -n "$MODULE_CONFLICTS" ]]; then
        for conflict in $MODULE_CONFLICTS; do
            if is_module_enabled "$conflict"; then
                print_error "Konflikt: Modul '$conflict' ist bereits aktiviert"
                print_info "Bitte erst './module.sh disable $conflict' ausfuehren"
                log_action "ENABLE" "$module_name" "ERROR" "Conflict with: $conflict"
                return 1
            fi
        done
    fi

    # Check GPU support
    load_env
    if [[ -n "$MODULE_GPU_SUPPORT" ]] && [[ "$MODULE_GPU_SUPPORT" != "all" ]]; then
        if [[ ! " $MODULE_GPU_SUPPORT " =~ " $GPU_MODE " ]]; then
            print_error "Modul erfordert GPU: $MODULE_GPU_SUPPORT (aktuell: $GPU_MODE)"
            log_action "ENABLE" "$module_name" "ERROR" "GPU incompatible: requires $MODULE_GPU_SUPPORT, have $GPU_MODE"
            return 1
        fi
    fi

    # Prepare module resources (data dirs, env vars, domain, setup script)
    if ! prepare_module_resources "$module_name"; then
        return 1
    fi

    # SSL mode switch: change install mode + update existing module domains
    if [[ "$module_name" == "ssl" ]]; then
        handle_ssl_mode_switch
        # Reload module conf overwritten by domain loop
        load_module_conf "$module_name"
    fi

    # Update ENABLED_MODULES (before reconcile so it sees the new module)
    reload_env
    local new_enabled="${ENABLED_MODULES} ${module_name}"
    new_enabled="${new_enabled# }"  # Trim leading space
    update_env_var "ENABLED_MODULES" "$new_enabled"
    print_success "Modul zu ENABLED_MODULES hinzugefuegt"

    # Reconcile COMPOSE_FILE — rebuild from scratch
    reconcile_compose

    # Reload module conf (reconcile_compose may have overwritten MODULE_* vars)
    load_module_conf "$module_name"

    # Update homepage configuration
    update_homepage_config

    # Create module database if needed
    if [[ -n "$MODULE_DB" ]]; then
        ensure_module_database "$MODULE_DB"
    fi

    # Start/apply services
    if [[ -n "$MODULE_SERVICES" ]]; then
        if ! start_module_services "$module_name" "$MODULE_SERVICES"; then
            return 1
        fi
    fi

    # Run post-enable script if present (e.g., certificate issuance, Keycloak setup)
    local post_enable_script="$MODULES_DIR/$module_name/post-enable.sh"
    if [[ -f "$post_enable_script" ]]; then
        print_step "Post-Enable Script ausfuehren"
        if ! bash "$post_enable_script"; then
            print_warning "Post-Enable Script hatte Fehler"
            log_action "ENABLE" "$module_name" "WARNING" "Post-enable script had errors"
        fi
    fi

    # Reconcile SSO — register module with Keycloak if SSO is active
    reconcile_sso

    # Log success
    log_action "ENABLE" "$module_name" "SUCCESS" "Enabled with mode=${INSTALL_MODE:-base}, gpu=${GPU_MODE:-cpu}"

    # Show access information (only for top-level call)
    if [[ -z "$visited" ]]; then
        show_enable_result "$module_name"
    fi

    return 0
}

cmd_enable() {
    local module_name="$1"

    # Create state backup
    create_state_backup

    # Try to enable module
    if ! cmd_enable_internal "$module_name" ""; then
        print_error "Fehler beim Aktivieren von Modul: $module_name"
        print_warning "Fuehre Rollback durch..."
        restore_state_backup
        return 1
    fi

    return 0
}

cmd_disable() {
    local module_name="$1"

    # Check if enabled
    if ! is_module_enabled "$module_name"; then
        print_warning "Modul '$module_name' ist nicht aktiviert"
        exit 0
    fi

    # Load module configuration
    if ! load_module_conf "$module_name"; then
        exit 1
    fi

    print_header "Modul deaktivieren: ${MODULE_NAME}"

    # Create state backup
    create_state_backup

    # Check if other modules depend on this one
    load_env
    local dependent_modules=""
    for other_module in $ENABLED_MODULES; do
        if [[ "$other_module" == "$module_name" ]]; then
            continue
        fi

        if load_module_conf "$other_module" 2>/dev/null; then
            if [[ " $MODULE_DEPENDS " =~ " $module_name " ]]; then
                dependent_modules="${dependent_modules} ${other_module}"
            fi
        fi
    done

    if [[ -n "$dependent_modules" ]]; then
        print_error "Folgende Module haengen von '$module_name' ab:${dependent_modules}"
        print_info "Bitte erst diese Module deaktivieren"
        log_action "DISABLE" "$module_name" "ERROR" "Has dependents:${dependent_modules}"
        exit 1
    fi

    # Reload module conf (was overwritten by dependency check)
    load_module_conf "$module_name"

    # Stop module services
    if [[ -n "$MODULE_SERVICES" ]]; then
        print_step "Services stoppen"
        for service in $MODULE_SERVICES; do
            stop_service "$service"
        done
    fi

    # SSL mode switch: restore base mode
    if [[ "$module_name" == "ssl" ]]; then
        update_env_var "INSTALL_MODE" "base"
    fi

    # Remove from ENABLED_MODULES
    reload_env
    local new_enabled=""
    for mod in $ENABLED_MODULES; do
        if [[ "$mod" != "$module_name" ]]; then
            new_enabled="${new_enabled} ${mod}"
        fi
    done
    new_enabled="${new_enabled## }"  # Trim leading space
    new_enabled="${new_enabled%% }"  # Trim trailing space
    update_env_var "ENABLED_MODULES" "$new_enabled"
    print_success "Modul aus ENABLED_MODULES entfernt"

    # Reconcile COMPOSE_FILE — rebuild from scratch
    reconcile_compose

    # Apply compose changes to remaining services (removes SSO labels, switches port mode, etc.)
    # --remove-orphans removes containers for services no longer defined in COMPOSE_FILE
    if ! $DRY_RUN; then
        cd "$PROJECT_ROOT"
        if ! docker compose up -d --remove-orphans 2>&1; then
            print_warning "docker compose up returned an error during reconciliation"
        fi
    fi

    # Update homepage configuration
    update_homepage_config

    # Log success
    log_action "DISABLE" "$module_name" "SUCCESS" "Disabled successfully"

    echo ""
    echo -e "  ${BOLD}Modul deaktiviert!${NC}"
    echo ""
}

# ─── Main ─────────────────────────────────────────────────────
main() {
    local command="${1:-}"

    # Check for --dry-run flag
    for arg in "$@"; do
        if [[ "$arg" == "--dry-run" ]]; then
            DRY_RUN=true
            print_warning "DRY-RUN Modus aktiviert (keine Aenderungen werden durchgefuehrt)"
            echo ""
        fi
    done

    case "$command" in
        list)
            cmd_list
            ;;
        status)
            cmd_status
            ;;
        verify)
            cmd_verify
            ;;
        urls)
            cmd_urls "${2:-}"
            ;;
        ports)
            cmd_ports
            ;;
        containers)
            cmd_containers
            ;;
        info)
            if [[ -z "${2:-}" ]]; then
                print_error "Verwendung: $0 info <modul-name>"
                exit 1
            fi
            cmd_info "$2"
            ;;
        gpu)
            if [[ -n "${2:-}" ]] && ! $DRY_RUN; then
                acquire_lock
            fi
            cmd_gpu "${2:-}"
            ;;
        setup)
            if [[ -z "${2:-}" ]]; then
                print_error "Verwendung: $0 setup <modul-name>"
                exit 1
            fi
            cmd_setup "$2"
            ;;
        enable)
            # Collect module names (skip flags like --dry-run)
            local modules=()
            for arg in "${@:2}"; do
                [[ "$arg" == --* ]] && continue
                modules+=("$arg")
            done

            if [[ ${#modules[@]} -eq 0 ]]; then
                print_error "Verwendung: $0 enable <modul-name>... [--dry-run]"
                exit 1
            fi

            # Acquire lock for write operations
            if ! $DRY_RUN; then
                acquire_lock
            fi

            local failed=false
            for mod in "${modules[@]}"; do
                if ! cmd_enable "$mod"; then
                    failed=true
                fi
            done
            if $failed; then exit 1; fi
            ;;
        disable)
            # Collect module names (skip flags like --dry-run)
            local modules=()
            for arg in "${@:2}"; do
                [[ "$arg" == --* ]] && continue
                modules+=("$arg")
            done

            if [[ ${#modules[@]} -eq 0 ]]; then
                print_error "Verwendung: $0 disable <modul-name>... [--dry-run]"
                exit 1
            fi

            # Acquire lock for write operations
            if ! $DRY_RUN; then
                acquire_lock
            fi

            local failed=false
            for mod in "${modules[@]}"; do
                cmd_disable "$mod" || failed=true
            done
            if $failed; then exit 1; fi
            ;;
        "")
            echo ""
            echo "  ancroo-stack — Modul Manager"
            echo ""
            echo "  Verwendung:"
            echo "    $0 list                       Verfuegbare Module anzeigen"
            echo "    $0 status                     Aktivierte Module anzeigen"
            echo "    $0 verify                     Container + HTTP health checks"
            echo "    $0 urls [ip]                  Service-URLs anzeigen (mit IP: /etc/hosts Format)"
            echo "    $0 ports                      Module mit Ports und Status"
            echo "    $0 containers                 Interne Docker-Adressen (ai-network)"
            echo "    $0 info <name>                Modul-Details anzeigen"
            echo "    $0 gpu [cpu|nvidia|rocm]      GPU-Modus anzeigen/wechseln"
            echo "    $0 setup <name>               Modul-Setup (erneut) ausfuehren"
            echo "    $0 enable <name>... [--dry-run]  Modul(e) aktivieren"
            echo "    $0 disable <name>... [--dry-run] Modul(e) deaktivieren"
            echo ""
            echo "  Optionen:"
            echo "    --dry-run                     Aenderungen nur simulieren"
            echo ""
            ;;
        *)
            print_error "Unbekannter Befehl: $command"
            echo ""
            echo "  Verwendung: $0 {list|status|verify|urls|ports|containers|info|gpu|setup|enable|disable} [name...]"
            echo ""
            exit 1
            ;;
    esac
}

main "$@"
