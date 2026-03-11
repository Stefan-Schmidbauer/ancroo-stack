#!/bin/bash
# env-generator.sh — Generate .env for ancroo-stack base installation

detect_local_ip() {
    local ip
    ip=$(hostname -I 2>/dev/null | awk '{print $1}')
    if [[ -z "$ip" ]]; then
        ip=$(hostname 2>/dev/null)
    fi
    echo "${ip:-localhost}"
}

generate_password() {
    local result=""
    local attempts=0
    while [[ ${#result} -lt 32 ]] && [[ $attempts -lt 5 ]]; do
        result+=$(head -c 256 /dev/urandom | tr -dc 'A-Za-z0-9') || true
        attempts=$((attempts + 1))
    done
    if [[ ${#result} -lt 32 ]]; then
        print_error "Failed to generate secure password"
        exit 1
    fi
    echo "${result:0:32}"
}

generate_secret_key() {
    openssl rand -base64 48 2>/dev/null | tr -d '\n' || generate_password
}

detect_amd_gpu_arch() {
    # Read GPU architecture from KFD topology (no userspace tools needed)
    local gfx_version=""
    for node_dir in /sys/class/kfd/kfd/topology/nodes/*/; do
        local props="$node_dir/properties"
        [[ -f "$props" ]] || continue
        local target
        target=$(grep '^gfx_target_version' "$props" 2>/dev/null | awk '{print $2}')
        # Skip CPU nodes (gfx_target_version 0)
        if [[ -n "$target" && "$target" != "0" ]]; then
            gfx_version="$target"
            break
        fi
    done
    # Fallback: try rocminfo
    if [[ -z "$gfx_version" ]] && command -v rocminfo &>/dev/null; then
        gfx_version=$(rocminfo 2>/dev/null | grep -oP 'gfx\K[0-9]+' | head -1)
    fi
    echo "$gfx_version"
}

write_rocm_gpu_env() {
    # Detect GPU and write appropriate env vars for ROCm mode
    local gfx_version
    gfx_version=$(detect_amd_gpu_arch)

    if [[ -z "$gfx_version" ]]; then
        print_warning "No AMD GPU detected — ROCm will run in CPU fallback mode"
        return
    fi

    # gfx_target_version format: MMPPP (e.g. 110501 = gfx1151, 110000 = gfx1100)
    case "$gfx_version" in
        110501|1151|110500|1105)
            # gfx1151 (RDNA 4 / Strix Halo) or gfx1105 (RDNA 3 iGPU)
            # ROCm 7.x supports gfx1151 natively. The stable ollama:rocm tag ships ROCm 6.x which crashes.
            # Pin to a ROCm 7.x image until the stable tag catches up.
            # IMPORTANT: after pulling models, patch each modelfile with PARAMETER num_gpu 99
            # See: modules/gpu-rocm/README.md
            print_info "GPU: gfx${gfx_version} (RDNA 4 iGPU) detected — using ROCm 7.x backend"
            cat >> "$PROJECT_ROOT/.env" << 'GPUEOF'

# Ollama GPU (auto-detected: gfx1151 / RDNA 4 — ROCm 7.x mode)
# Update OLLAMA_IMAGE_TAG to "rocm" once the stable tag ships ROCm 7.x
# IMPORTANT: set num_gpu=99 in Open WebUI (Admin → Settings → Models → Default Model Settings)
#            or patch each modelfile — see modules/gpu-rocm/README.md
OLLAMA_IMAGE_TAG="0.17.8-rc1-rocm"
HIP_VISIBLE_DEVICES="0"
OLLAMA_FLASH_ATTENTION="true"
GPUEOF
            ;;
        110000|110100|110200|1100|1101|1102)
            # RDNA 3 (discrete) — native HIP support
            print_info "GPU: RDNA 3 detected — using native HIP backend"
            ;;
        103000|1030)
            # RDNA 2 — native HIP support
            print_info "GPU: RDNA 2 detected — using native HIP backend"
            ;;
        90800|90a00|94200|95000|908|90a|942|950)
            # MI-series (data center) — native HIP support
            print_info "GPU: AMD Instinct detected — using native HIP backend"
            ;;
        *)
            print_warning "GPU architecture $gfx_version not explicitly supported"
            print_warning "HIP will be attempted — if issues occur, set HSA_OVERRIDE_GFX_VERSION in .env"
            ;;
    esac
}

create_base_env() {
    local timezone="$1"
    local gpu_mode="$2"
    local hostname
    hostname=$(detect_local_ip)
    # Export for use in install.sh (Homepage config, summary output)
    DETECTED_HOST_IP="$hostname"

    local pg_user="ancroo"
    local pg_pass
    local pg_db="ancroo"

    # Check if PostgreSQL data already exists
    if [[ -d "$PROJECT_ROOT/data/postgresql" ]] && [[ -n "$(ls -A "$PROJECT_ROOT/data/postgresql" 2>/dev/null)" ]]; then
        # Try to read existing password from .env
        if [[ -f "$PROJECT_ROOT/.env" ]]; then
            local existing_pass
            existing_pass=$(grep '^POSTGRES_PASSWORD=' "$PROJECT_ROOT/.env" 2>/dev/null | cut -d'=' -f2-)
            if [[ -n "$existing_pass" ]]; then
                pg_pass="$existing_pass"
                print_info "Using existing PostgreSQL password (data directory present)"
            fi
        fi
        # If no existing password found but data exists, warn user
        if [[ -z "$pg_pass" ]]; then
            print_warning "PostgreSQL data exists but no password found in .env!"
            print_warning "Either add the old password to .env or delete data/postgresql"
            pg_pass=$(generate_password)
        fi
    else
        pg_pass=$(generate_password)
    fi
    local webui_secret
    webui_secret=$(generate_secret_key)
    local docker_gid
    docker_gid=$(detect_docker_gid)

    local compose_file="docker-compose.yml:docker-compose.ports.yml"
    if [[ "$gpu_mode" != "cpu" ]]; then
        compose_file="docker-compose.yml:modules/gpu-${gpu_mode}/compose.yml:docker-compose.ports.yml"
    fi

    local enabled_modules=""
    if [[ "$gpu_mode" != "cpu" ]]; then
        enabled_modules="gpu-${gpu_mode}"
    fi

    cat > "$PROJECT_ROOT/.env" << EOF
# ancroo-stack — Base Configuration
# Generated: $(date '+%Y-%m-%d %H:%M:%S')

# System
TZ="${timezone}"
GPU_MODE="${gpu_mode}"
INSTALL_MODE="base"
COMPOSE_FILE="${compose_file}"
ENABLED_MODULES="${enabled_modules}"

# PostgreSQL
POSTGRES_USER="${pg_user}"
POSTGRES_PASSWORD="${pg_pass}"
POSTGRES_DB="${pg_db}"
DATABASE_URL="postgresql://${pg_user}:${pg_pass}@postgres:5432/${pg_db}"

# Open WebUI
WEBUI_SECRET_KEY="${webui_secret}"

# Homepage Dashboard
PUID="$(id -u)"
DOCKER_GID="${docker_gid}"

# Host (for access URLs)
HOST_IP="${hostname}"
EOF

    chmod 640 "$PROJECT_ROOT/.env"

    # Auto-detect GPU architecture and write backend-specific vars
    if [[ "$gpu_mode" == "rocm" ]]; then
        write_rocm_gpu_env
    fi

    print_success ".env created"
}

create_password_summary() {
    local summary_dir="$PROJECT_ROOT/logs"
    mkdir -p "$summary_dir"
    local summary_file="$summary_dir/install-summary-$(date '+%Y%m%d-%H%M%S').txt"

    local pg_pass
    pg_pass=$(grep '^POSTGRES_PASSWORD=' "$PROJECT_ROOT/.env" | cut -d'=' -f2-)

    cat > "$summary_file" << EOF
ancroo-stack — Installation Summary
==============================
Generated: $(date '+%Y-%m-%d %H:%M:%S')

PostgreSQL:
  User:     $(grep '^POSTGRES_USER=' "$PROJECT_ROOT/.env" | cut -d'=' -f2-)
  Password: ${pg_pass}
  Database: $(grep '^POSTGRES_DB=' "$PROJECT_ROOT/.env" | cut -d'=' -f2-)

GPU Mode: $(grep '^GPU_MODE=' "$PROJECT_ROOT/.env" | cut -d'=' -f2-)

Access URLs:
  Open WebUI: http://$(grep '^HOST_IP=' "$PROJECT_ROOT/.env" | cut -d'=' -f2-):8080
  Homepage:   http://$(grep '^HOST_IP=' "$PROJECT_ROOT/.env" | cut -d'=' -f2-)
  Ollama API: http://$(grep '^HOST_IP=' "$PROJECT_ROOT/.env" | cut -d'=' -f2-):11434
EOF

    chmod 600 "$summary_file"
    print_success "Credentials saved: $summary_file"
}
