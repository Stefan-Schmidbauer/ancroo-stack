#!/bin/bash
# ancroo-stack — Guided Installer
#
# Installs the full AI stack in one run:
#   Base:       PostgreSQL, Ollama, Open WebUI, Homepage
#   Workflows:  n8n, Ancroo Backend (if available)
#   STT:        Speaches, Whisper-ROCm (selectable)
#   Tools:      Adminer
#   Extension:  Ancroo Browser Extension (if available)
#
# Interactive by default. Non-interactive via environment variables:
#   ANCROO_GPU_MODE        — nvidia | rocm | cpu (default: interactive prompt)
#   ANCROO_TIMEZONE        — timezone string (default: auto-detect)
#   ANCROO_OLLAMA_MODEL    — model name to pull, "none" or empty = skip (default: interactive prompt)
#   ANCROO_STT_MODULES     — "1" | "2" | "1,2" | "all" (default: interactive prompt)
#   ANCROO_BOOKSTACK       — "y" | "n" (default: interactive prompt)
#   ANCROO_NONINTERACTIVE  — set to skip all prompts (uses defaults or env vars above)
#   ANCROO_FORCE_REINSTALL — set to "1" to overwrite existing .env
#
# Usage:
#   bash install.sh                                          # interactive
#   bash install.sh --dev                                    # build from source
#   ANCROO_GPU_MODE=rocm ANCROO_NONINTERACTIVE=1 bash install.sh  # non-interactive
set -euo pipefail

# ─── Setup ────────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$SCRIPT_DIR"
WORKSPACE_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
BACKEND_DIR="${WORKSPACE_ROOT}/ancroo-backend"
RUNNER_DIR="${WORKSPACE_ROOT}/ancroo-runner"
WEB_DIR="${WORKSPACE_ROOT}/ancroo-web"

source "$SCRIPT_DIR/tools/install/lib/common.sh"
source "$SCRIPT_DIR/tools/install/lib/validation.sh"
source "$SCRIPT_DIR/tools/install/lib/env-generator.sh"
source "$SCRIPT_DIR/tools/install/lib/homepage.sh"

cd "$PROJECT_ROOT"

# Parse flags
DEV_MODE=false
for arg in "$@"; do
    case "$arg" in
        --dev) DEV_MODE=true ;;
    esac
done

# ─────────────────────────────────────────────────────────
# PRE-FLIGHT CHECKS
# ─────────────────────────────────────────────────────────
print_header "Ancroo Stack — Installer"

run_preflight_checks

# Check for existing installation
EXISTING_INSTALL=false
if ! check_existing_installation; then
    EXISTING_INSTALL=true
fi

if ! command -v git &>/dev/null; then
    print_warning "git is not installed — some features may not work"
fi
echo ""

# ─────────────────────────────────────────────────────────
# CONFIGURATION WIZARD
# ─────────────────────────────────────────────────────────
print_header "Configuration"

# --- GPU mode ---
if [[ -n "${ANCROO_GPU_MODE:-}" ]]; then
    case "$ANCROO_GPU_MODE" in
        nvidia) WIZARD_GPU_MODE="nvidia" ;;
        rocm)   WIZARD_GPU_MODE="rocm" ;;
        *)      WIZARD_GPU_MODE="cpu" ;;
    esac
elif $EXISTING_INSTALL; then
    WIZARD_GPU_MODE=$(grep "^GPU_MODE=" "$PROJECT_ROOT/.env" 2>/dev/null | sed 's/^[^=]*=//;s/^"//;s/"$//' || echo "cpu")
else
    echo "  GPU acceleration for Ollama:"
    echo "    1) CPU only (no GPU)"
    echo "    2) NVIDIA (CUDA)"
    echo "    3) AMD (ROCm)"
    echo ""
    echo -ne "  Selection [1-3]: "
    read -r gpu_choice_input
    case "$gpu_choice_input" in
        2) WIZARD_GPU_MODE="nvidia" ;;
        3) WIZARD_GPU_MODE="rocm" ;;
        *)  WIZARD_GPU_MODE="cpu" ;;
    esac
fi
print_success "GPU: ${WIZARD_GPU_MODE}"

# Derive workflow backends from GPU mode
case "$WIZARD_GPU_MODE" in
    nvidia) WIZARD_BACKENDS="cuda" ;;
    rocm)   WIZARD_BACKENDS="rocm" ;;
    *)      WIZARD_BACKENDS="cuda" ;;
esac

# --- Ollama model ---
if [[ -n "${ANCROO_OLLAMA_MODEL:-}" ]]; then
    OLLAMA_PULL_MODEL="$ANCROO_OLLAMA_MODEL"
    [[ "$OLLAMA_PULL_MODEL" == "none" ]] && OLLAMA_PULL_MODEL=""
elif [[ -n "${ANCROO_NONINTERACTIVE:-}" ]]; then
    OLLAMA_PULL_MODEL=""
else
    echo ""
    print_step "Ollama model"
    echo ""
    echo "  Download an LLM during installation?"
    echo ""
    echo "    1) Mistral 7B        — fast general-purpose        (~4.1 GB)"
    echo "    2) Llama 3.1 8B      — versatile, multilingual     (~4.7 GB)"
    echo "    3) Gemma 2 2B        — lightweight, fast            (~1.6 GB)"
    echo "    4) Phi-3 Mini 3.8B   — compact, efficient           (~2.3 GB)"
    echo ""
    echo -ne "  Selection [1-4, Enter=none]: "
    read -r ollama_model_choice
    OLLAMA_PULL_MODEL=""
    case "$ollama_model_choice" in
        1) OLLAMA_PULL_MODEL="mistral" ;;
        2) OLLAMA_PULL_MODEL="llama3.1" ;;
        3) OLLAMA_PULL_MODEL="gemma2:2b" ;;
        4) OLLAMA_PULL_MODEL="phi3:mini" ;;
    esac
fi
if [[ -n "${OLLAMA_PULL_MODEL:-}" ]]; then
    print_success "Ollama model: ${OLLAMA_PULL_MODEL}"
else
    print_info "Ollama model: none (can be pulled later via Open WebUI)"
fi

# --- BookStack (optional) ---
if [[ -n "${ANCROO_BOOKSTACK:-}" ]]; then
    ENABLE_BOOKSTACK="${ANCROO_BOOKSTACK}"
elif [[ -n "${ANCROO_NONINTERACTIVE:-}" ]]; then
    ENABLE_BOOKSTACK="n"
else
    echo ""
    ENABLE_BOOKSTACK="n"
    confirm "Include BookStack (wiki / knowledge base, port 8875)?" "y" && ENABLE_BOOKSTACK="y" || true
fi

if [[ "$ENABLE_BOOKSTACK" == "y" ]]; then
    WIZARD_BOOKSTACK_EMAIL="admin@admin.com"
    WIZARD_BOOKSTACK_PASSWORD=$(openssl rand -base64 12)
    print_info "BookStack admin: ${WIZARD_BOOKSTACK_EMAIL} (password auto-generated)"
fi

# --- STT module selection ---
if [[ -n "${ANCROO_STT_MODULES:-}" ]]; then
    _stt_choice="$ANCROO_STT_MODULES"
elif [[ -n "${ANCROO_NONINTERACTIVE:-}" ]]; then
    _stt_choice="1"
else
    echo ""
    print_step "STT modules (Speech-to-Text)"
    echo ""
    echo "    1) Speaches         — multi-model, CPU or GPU (CUDA)      (port 8100)"
    if [[ "$WIZARD_GPU_MODE" == "rocm" ]]; then
        echo "    2) Whisper ROCm     — AMD GPU-accelerated                 (port 8002)"
        echo ""
        echo -ne "  Select STT modules (comma-separated, e.g. 1,2 or 'all') [1]: "
    else
        echo ""
        echo -ne "  Select STT modules [1]: "
    fi
    read -r _stt_choice
    _stt_choice="${_stt_choice:-1}"
fi

ENABLE_SPEACHES="n"
ENABLE_WHISPER_ROCM="n"

if [[ "$_stt_choice" == "all" ]]; then
    ENABLE_SPEACHES="y"
    [[ "$WIZARD_GPU_MODE" == "rocm" ]] && ENABLE_WHISPER_ROCM="y"
else
    IFS=',' read -ra _stt_parts <<< "$_stt_choice"
    for _part in "${_stt_parts[@]}"; do
        _part="$(echo "$_part" | tr -d ' ')"
        case "$_part" in
            1) ENABLE_SPEACHES="y" ;;
            2) [[ "$WIZARD_GPU_MODE" == "rocm" ]] && ENABLE_WHISPER_ROCM="y" ;;
        esac
    done
fi

# Ensure at least one STT module is selected
if [[ "$ENABLE_SPEACHES" != "y" && "$ENABLE_WHISPER_ROCM" != "y" ]]; then
    ENABLE_SPEACHES="y"
    print_warning "No valid STT module selected — defaulting to Speaches"
fi

_stt_selected=""
[[ "$ENABLE_SPEACHES" == "y" ]] && _stt_selected+="speaches "
[[ "$ENABLE_WHISPER_ROCM" == "y" ]] && _stt_selected+="whisper-rocm "
print_success "STT: ${_stt_selected% }"

# --- Ancroo Backend + Extension ---
ENABLE_BACKEND=false
ENABLE_EXTENSION=false

if [[ -d "$BACKEND_DIR" ]]; then
    ENABLE_BACKEND=true
    print_success "Ancroo Backend: found at ${BACKEND_DIR}"
else
    print_info "Ancroo Backend: not found (${BACKEND_DIR}) — skipping"
fi

ENABLE_RUNNER=false

if [[ -d "$RUNNER_DIR" ]]; then
    ENABLE_RUNNER=true
    print_success "Ancroo Runner: found at ${RUNNER_DIR}"
else
    print_info "Ancroo Runner: not found (${RUNNER_DIR}) — skipping"
fi

if [[ -d "$WEB_DIR" ]]; then
    ENABLE_EXTENSION=true
    print_success "Ancroo Extension: found at ${WEB_DIR}"
else
    print_info "Ancroo Extension: not found (${WEB_DIR}) — skipping"
fi

# ─── Port conflict check ─────────────────────────────────
get_module_port() {
    local conf_file="$1"
    [[ -f "$conf_file" ]] || return 1
    (
        MODULE_PORT=""
        source "$conf_file"
        echo "$MODULE_PORT"
    )
}

declare -A PORT_CHECK_MAP
# Base services (fixed — defined in docker-compose.ports.yml)
PORT_CHECK_MAP[80]="Homepage"
PORT_CHECK_MAP[8080]="Open WebUI"
PORT_CHECK_MAP[11434]="Ollama"

# Core modules — check their ports
for _pcm in n8n adminer; do
    _pcm_port=$(get_module_port "$PROJECT_ROOT/modules/$_pcm/module.conf") || true
    [[ -n "${_pcm_port:-}" ]] && PORT_CHECK_MAP[$_pcm_port]="$_pcm"
done

# STT modules (user-selected)
for _stt_mod in speaches whisper-rocm; do
    _stt_var="ENABLE_$(echo "$_stt_mod" | tr '[:lower:]-' '[:upper:]_')"
    if [[ "${!_stt_var}" == "y" ]]; then
        _pcm_port=$(get_module_port "$PROJECT_ROOT/modules/$_stt_mod/module.conf") || true
        [[ -n "${_pcm_port:-}" ]] && PORT_CHECK_MAP[$_pcm_port]="$_stt_mod"
    fi
done
if [[ "$ENABLE_BOOKSTACK" == "y" ]]; then
    _pcm_port=$(get_module_port "$PROJECT_ROOT/modules/bookstack/module.conf") || true
    [[ -n "${_pcm_port:-}" ]] && PORT_CHECK_MAP[$_pcm_port]="bookstack"
fi

# Ancroo Backend (module.conf lives in ancroo-backend repo)
if $ENABLE_BACKEND; then
    ancroo_port=$(get_module_port "$BACKEND_DIR/module/module.conf") || true
    [[ -n "${ancroo_port:-}" ]] && PORT_CHECK_MAP[$ancroo_port]="Ancroo Backend"
fi

# Ancroo Runner (module.conf in runner repo or already installed in stack)
if $ENABLE_RUNNER; then
    if [[ -f "$RUNNER_DIR/module/module.conf" ]]; then
        runner_port=$(get_module_port "$RUNNER_DIR/module/module.conf") || true
    elif [[ -f "$PROJECT_ROOT/modules/ancroo-runner/module.conf" ]]; then
        runner_port=$(get_module_port "$PROJECT_ROOT/modules/ancroo-runner/module.conf") || true
    fi
    [[ -n "${runner_port:-}" ]] && PORT_CHECK_MAP[$runner_port]="Ancroo Runner"
fi

blocked_ports=()
for port in "${!PORT_CHECK_MAP[@]}"; do
    if ! check_port_available "$port"; then
        blocked_ports+=("$port (${PORT_CHECK_MAP[$port]})")
    fi
done

if [[ ${#blocked_ports[@]} -gt 0 ]]; then
    echo ""
    print_warning "The following ports are already in use:"
    for entry in "${blocked_ports[@]}"; do
        echo -e "    ${YELLOW}→${NC} Port $entry"
    done
    echo ""
    print_info "An existing installation or service may be blocking these ports."
    if [[ -n "${ANCROO_NONINTERACTIVE:-}" ]]; then
        print_info "Non-interactive mode: continuing despite port conflicts"
    elif ! confirm "Continue anyway?" "n"; then
        exit 0
    fi
fi

# ─── Pre-flight summary ──────────────────────────────────
stt_list=""
[[ "$ENABLE_SPEACHES" == "y" ]] && stt_list+="speaches "
[[ "$ENABLE_WHISPER_ROCM" == "y" ]] && stt_list+="whisper-rocm "
stt_list="${stt_list% }"

echo ""
echo -e "  ${BOLD}═══════════════════════════════════════════════════════${NC}"
echo -e "  ${BOLD}  Installation plan${NC}"
echo -e "  ${BOLD}═══════════════════════════════════════════════════════${NC}"
echo ""
echo "  Mode:          base (http://IP:port)"
echo "  GPU:           ${WIZARD_GPU_MODE}"
echo "  STT:           ${stt_list}"
echo "  Core modules:  n8n adminer"
[[ "$ENABLE_BOOKSTACK" == "y" ]] && echo "  Optional:      bookstack"
echo "  Ollama model:  ${OLLAMA_PULL_MODEL:-none}"
$ENABLE_BACKEND && echo "  Ancroo:        backend" || true
$ENABLE_RUNNER && echo "  Runner:        ancroo-runner" || true
$ENABLE_EXTENSION && echo "  Extension:     browser extension" || true
echo ""
echo -e "  ${YELLOW}SSL, SSO — experimental, available via module.sh${NC}"
echo ""
if [[ -z "${ANCROO_NONINTERACTIVE:-}" ]]; then
    echo -e "  ${YELLOW}Press Enter to start, Ctrl+C to cancel.${NC}"
    read -r
fi

if $DEV_MODE; then
    print_info "Dev mode (--dev): will build backend, runner, and extension from local source"
fi

# ─────────────────────────────────────────────────────────
# BASE INSTALLATION
# ─────────────────────────────────────────────────────────
if $EXISTING_INSTALL; then
    print_header "Base Installation — Skipped"
    print_info "Existing .env found — using current configuration"
    print_info "To re-install, set ANCROO_FORCE_REINSTALL=1"

    # Sync GPU mode if user selected a different one
    _existing_gpu=$(grep "^GPU_MODE=" "$PROJECT_ROOT/.env" 2>/dev/null | sed 's/^[^=]*=//;s/^"//;s/"$//' || echo "cpu")
    if [[ "$WIZARD_GPU_MODE" != "$_existing_gpu" ]]; then
        print_warning "GPU mode mismatch: .env has '$_existing_gpu', selected '$WIZARD_GPU_MODE'"
        print_step "Switching GPU mode via module.sh..."
        if bash "$PROJECT_ROOT/module.sh" gpu "$WIZARD_GPU_MODE"; then
            print_success "GPU mode updated to: $WIZARD_GPU_MODE"
        else
            print_error "Failed to switch GPU mode"
            exit 1
        fi
    fi
else
    print_header "Base Installation"

    # Timezone
    current_tz=$(timedatectl show -p Timezone --value 2>/dev/null || echo "Europe/Berlin")
    timezone="${ANCROO_TIMEZONE:-$current_tz}"
    print_info "Timezone: $timezone"

    # Generate .env
    print_step "Generating configuration"
    export ANCROO_GPU_MODE="$WIZARD_GPU_MODE"
    create_base_env "$timezone" "$WIZARD_GPU_MODE"

    # Create directories
    print_step "Creating directories"
    if [[ -d data ]] && [[ ! -w data ]]; then
        sudo chown "$(id -u):$(id -g)" data
    fi
    mkdir -p data/{ollama,open-webui,postgresql,homepage}
    chown "$(id -u):$(id -g)" data/{ollama,open-webui,postgresql,homepage}
    mkdir -p logs
    print_success "Data directories created"

    # Homepage configuration
    print_step "Configuring Homepage dashboard"
    setup_homepage

    # Password summary
    create_password_summary

    # Start base services
    print_step "Starting Docker containers"
    docker compose up -d

    echo ""
    print_info "Waiting for services to start..."
    failed_count=0
    max_wait=60
    waited=0
    while [[ $waited -lt $max_wait ]]; do
        all_running=true
        for container in postgres ollama open-webui homepage; do
            if ! docker ps --format '{{.Names}}' | grep -q "^${container}$"; then
                all_running=false
                break
            fi
        done
        if $all_running; then
            break
        fi
        sleep 2
        waited=$((waited + 2))
    done

    for container in postgres ollama open-webui homepage; do
        if docker ps --format '{{.Names}}' | grep -q "^${container}$"; then
            print_success "$container running"
        else
            print_error "$container failed to start"
            failed_count=$((failed_count + 1))
        fi
    done

    # Restart homepage to ensure config is loaded on first install
    docker restart homepage >/dev/null 2>&1 || true

    if [[ $failed_count -gt 0 ]]; then
        print_error "Base installation had failures"
        print_info "Check: docker compose logs"
        exit 1
    fi
fi

# ─────────────────────────────────────────────────────────
# OLLAMA MODEL (optional)
# ─────────────────────────────────────────────────────────
ollama_model="${OLLAMA_PULL_MODEL:-}"
ollama_model_pulled="n"

if [[ -n "$ollama_model" ]]; then
    print_step "Ollama model: ${ollama_model}"
    print_info "Waiting for Ollama API..."
    ollama_ready="n"
    for _i in $(seq 1 30); do
        if curl -sf "http://localhost:11434/api/tags" >/dev/null 2>&1; then
            ollama_ready="y"
            break
        fi
        sleep 2
    done

    if [[ "$ollama_ready" == "y" ]]; then
        # Check if model is already available
        if docker exec ollama ollama list 2>/dev/null | grep -q "^${ollama_model}"; then
            print_success "Model ${ollama_model} already installed"
            ollama_model_pulled="y"
        else
            print_info "Downloading ${ollama_model} — this may take a few minutes..."
            if docker exec ollama ollama pull "$ollama_model"; then
                print_success "Model ${ollama_model} ready"
                ollama_model_pulled="y"
            else
                print_warning "Model pull failed — you can pull it later via Open WebUI"
            fi
        fi
    else
        print_warning "Ollama not ready after 60s — you can pull the model later via Open WebUI"
    fi
fi

# ─────────────────────────────────────────────────────────
# MODULES
# ─────────────────────────────────────────────────────────
print_header "Modules"

# STT modules (user-selected)
[[ "$ENABLE_SPEACHES" == "y" ]] && bash ./module.sh enable speaches
[[ "$ENABLE_WHISPER_ROCM" == "y" ]] && bash ./module.sh enable whisper-rocm

# Tools: Adminer (DB UI)
bash ./module.sh enable adminer

# n8n (pre-enable so API key is generated before Ancroo setup)
bash ./module.sh enable n8n

# Optional: BookStack
if [[ "$ENABLE_BOOKSTACK" == "y" ]]; then
    export BOOKSTACK_ADMIN_EMAIL="${WIZARD_BOOKSTACK_EMAIL:-}"
    export BOOKSTACK_ADMIN_PASSWORD="${WIZARD_BOOKSTACK_PASSWORD:-}"
    bash ./module.sh enable bookstack
    unset BOOKSTACK_ADMIN_EMAIL BOOKSTACK_ADMIN_PASSWORD
fi

# ─────────────────────────────────────────────────────────
# ANCROO BACKEND
# ─────────────────────────────────────────────────────────
if $ENABLE_BACKEND; then
    print_header "Ancroo Backend"

    export ANCROO_INSTALL_OVERWRITE="y"
    export ANCROO_ENABLE_NOW="y"

    # Pass n8n API key to Ancroo setup
    N8N_KEY_FROM_ENV=$(grep "^ANCROO_N8N_API_KEY=" "$PROJECT_ROOT/.env" 2>/dev/null | head -1 | sed 's/^[^=]*=//;s/^"//;s/"$//' || true)
    if [[ -n "$N8N_KEY_FROM_ENV" ]]; then
        export ANCROO_N8N_API_KEY_INPUT="$N8N_KEY_FROM_ENV"
    fi

    # Pass selected Ollama model
    if [[ -n "${OLLAMA_PULL_MODEL:-}" ]]; then
        export ANCROO_OLLAMA_MODEL_INPUT="$OLLAMA_PULL_MODEL"
    fi

    # Pass selected workflow backends
    export ANCROO_BACKENDS_INPUT="$WIZARD_BACKENDS"

    if $DEV_MODE; then
        export ANCROO_LOCAL_BUILD="y"
        print_step "Dev mode: building ancroo-backend image from local source..."
        docker build \
            -t ghcr.io/ancroo/ancroo-backend:latest \
            --build-arg BUILD_COMMIT="$(cd "$BACKEND_DIR" && git rev-parse --short HEAD 2>/dev/null || echo dev)" \
            --build-arg BUILD_VERSION=dev \
            "$BACKEND_DIR"
        print_success "ancroo-backend image built from local source"
    else
        BACKEND_IMAGE="ghcr.io/ancroo/ancroo-backend:latest"
        print_step "Pulling backend image: ${BACKEND_IMAGE}"
        if docker pull "$BACKEND_IMAGE"; then
            print_success "Backend image pulled"
        else
            echo ""
            print_error "Could not pull ${BACKEND_IMAGE}"
            print_info "If the image is private, authenticate first:"
            print_info "  echo \$GHCR_TOKEN | docker login ghcr.io -u USERNAME --password-stdin"
            echo ""
            if [[ -n "${ANCROO_NONINTERACTIVE:-}" ]]; then
                print_error "Non-interactive mode: cannot continue without backend image"
                exit 1
            elif ! confirm "Continue without the backend image? (not recommended)" "n"; then
                print_info "Installation aborted — resolve the issue above and try again"
                exit 1
            fi
        fi
    fi

    bash "$BACKEND_DIR/install-stack.sh" "$PROJECT_ROOT"
    unset ANCROO_INSTALL_OVERWRITE ANCROO_ENABLE_NOW ANCROO_N8N_API_KEY_INPUT ANCROO_OLLAMA_MODEL_INPUT ANCROO_BACKENDS_INPUT
    $DEV_MODE && unset ANCROO_LOCAL_BUILD || true
fi

# ─────────────────────────────────────────────────────────
# ANCROO RUNNER
# ─────────────────────────────────────────────────────────
if $ENABLE_RUNNER; then
    print_header "Ancroo Runner"

    if $DEV_MODE; then
        export ANCROO_LOCAL_BUILD=y
        print_step "Dev mode: building ancroo-runner image from local source..."
        docker build \
            --build-arg BUILD_COMMIT="$(cd "$RUNNER_DIR" && git rev-parse --short HEAD 2>/dev/null || echo dev)" \
            -t ghcr.io/ancroo/ancroo-runner:latest \
            "$RUNNER_DIR"
        print_success "ancroo-runner image built from local source"
    else
        RUNNER_IMAGE="ghcr.io/ancroo/ancroo-runner:latest"
        print_step "Pulling runner image: ${RUNNER_IMAGE}"
        if docker pull "$RUNNER_IMAGE"; then
            print_success "Runner image pulled"
        else
            echo ""
            print_error "Could not pull ${RUNNER_IMAGE}"
            print_info "Check your Docker credentials or Internet connection"
            echo ""
            if [[ -n "${ANCROO_NONINTERACTIVE:-}" ]]; then
                print_warning "Non-interactive mode: continuing without runner (image not available)"
                ENABLE_RUNNER=false
            elif ! confirm "Continue without the runner?" "n"; then
                print_info "Installation aborted — resolve the issue and try again"
                exit 1
            else
                ENABLE_RUNNER=false
            fi
        fi
    fi

    if $ENABLE_RUNNER; then
        ANCROO_INSTALL_OVERWRITE=y ANCROO_ENABLE_NOW=y \
            bash "$RUNNER_DIR/install-stack.sh" "$PROJECT_ROOT"
        unset ANCROO_INSTALL_OVERWRITE ANCROO_ENABLE_NOW
        $DEV_MODE && unset ANCROO_LOCAL_BUILD || true
    fi
fi

# ─────────────────────────────────────────────────────────
# ANCROO EXTENSION
# ─────────────────────────────────────────────────────────
if $ENABLE_EXTENSION; then
    print_header "Ancroo Extension"

    if $DEV_MODE; then
        print_info "Dev mode: building extension from local source"
        bash "$WEB_DIR/build.sh"
    else
        EXTENSION_OK=false

        if ! command -v gh &>/dev/null; then
            print_error "gh CLI is not installed — cannot download the extension"
            print_info "Install it from: https://cli.github.com"
        elif ! gh auth status &>/dev/null 2>&1; then
            print_error "gh CLI is not authenticated — cannot download the extension"
            print_info "Run: gh auth login"
        else
            print_step "Downloading latest build artifact from GitHub Actions..."
            if gh run download \
                --repo ancroo/ancroo-web \
                --name ancroo-web-extension \
                --dir "$WEB_DIR/dist" 2>/dev/null; then
                print_success "Ancroo extension downloaded to ${WEB_DIR}/dist/"
                EXTENSION_OK=true
            else
                print_error "Artifact download failed"
                print_info "Check that the GitHub Actions build has completed successfully"
            fi
        fi

        if ! $EXTENSION_OK; then
            echo ""
            print_warning "The browser extension could not be installed"
            print_info "The extension is required for the full Ancroo experience"
            echo ""
            if [[ -n "${ANCROO_NONINTERACTIVE:-}" ]]; then
                print_warning "Non-interactive mode: continuing without extension"
            elif ! confirm "Continue installation without the extension?" "n"; then
                print_info "Installation aborted — resolve the issue above and run the installer again"
                exit 1
            fi
        fi
    fi
fi

# ─────────────────────────────────────────────────────────
# FINAL SUMMARY
# ─────────────────────────────────────────────────────────

# Read final state from .env
HOST_IP=$(grep "^HOST_IP=" "$PROJECT_ROOT/.env" 2>/dev/null | head -1 | sed 's/^[^=]*=//;s/^"//;s/"$//' || echo "localhost")

# --- Wait for containers to become healthy ---
echo ""
print_step "Waiting for all containers to become healthy..."
_wait_max=300
_wait_elapsed=0
_wait_interval=5
while [[ $_wait_elapsed -lt $_wait_max ]]; do
    _healthy=0
    _total=0
    _all_ready=true
    for _ctr in $(docker compose ps --format '{{.Name}}' 2>/dev/null); do
        _total=$((_total + 1))
        _h=$(docker inspect --format='{{if .State.Health}}{{.State.Health.Status}}{{else}}no-healthcheck{{end}}' "$_ctr" 2>/dev/null)
        _s=$(docker inspect --format='{{.State.Status}}' "$_ctr" 2>/dev/null || echo "unknown")
        if [[ "$_s" == "running" ]] && [[ "$_h" == "healthy" || "$_h" == "no-healthcheck" ]]; then
            _healthy=$((_healthy + 1))
        else
            _all_ready=false
        fi
    done
    if $_all_ready; then
        break
    fi
    printf "\r  ⏳  %d/%d containers healthy (%ds elapsed)...    " "$_healthy" "$_total" "$_wait_elapsed"
    sleep "$_wait_interval"
    _wait_elapsed=$((_wait_elapsed + _wait_interval))
done
printf "\r%80s\r" ""
if $_all_ready; then
    print_success "All $_total containers healthy"
else
    print_warning "$_healthy/$_total containers healthy after ${_wait_elapsed}s"
fi

# --- Final summary ---
echo ""
echo -e "  ${BOLD}${GREEN}═══════════════════════════════════════════════════════${NC}"
echo -e "  ${BOLD}${GREEN}  Installation complete!${NC}"
echo -e "  ${BOLD}${GREEN}═══════════════════════════════════════════════════════${NC}"
echo ""
echo -e "  ${BOLD}Container Status:${NC}"
_fp_warnings=()
for _fp_ctr in $(docker compose ps --format '{{.Name}}' 2>/dev/null); do
    _fp_health=$(docker inspect --format='{{if .State.Health}}{{.State.Health.Status}}{{else}}no-healthcheck{{end}}' "$_fp_ctr" 2>/dev/null)
    _fp_state=$(docker inspect --format='{{.State.Status}}' "$_fp_ctr" 2>/dev/null || echo "unknown")
    if [[ "$_fp_state" == "running" ]]; then
        if [[ "$_fp_health" == "healthy" || "$_fp_health" == "no-healthcheck" ]]; then
            print_success "$_fp_ctr"
        else
            print_warning "$_fp_ctr ($_fp_health)"
            _fp_warnings+=("$_fp_ctr is not healthy ($_fp_health)")
        fi
    else
        print_error "$_fp_ctr ($_fp_state)"
        _fp_warnings+=("$_fp_ctr is not running ($_fp_state)")
    fi
done
echo ""
echo -e "  ${BOLD}Services:${NC}"
echo -e "    Open WebUI:     ${CYAN}http://${HOST_IP}:8080${NC}"
echo -e "    Homepage:       ${CYAN}http://${HOST_IP}${NC}"
echo -e "    Ollama API:     ${CYAN}http://${HOST_IP}:11434${NC}"

echo ""
echo -e "  ${BOLD}STT modules:${NC}"
[[ "$ENABLE_SPEACHES" == "y" ]] && echo -e "    Speaches:       ${CYAN}http://${HOST_IP}:8100${NC}"
[[ "$ENABLE_WHISPER_ROCM" == "y" ]] && echo -e "    Whisper ROCm:   ${CYAN}http://${HOST_IP}:8002${NC}"

N8N_PORT_FINAL=$(grep "^N8N_PORT=" "$PROJECT_ROOT/.env" 2>/dev/null | head -1 | sed 's/^[^=]*=//;s/^"//;s/"$//' || echo "5678")
echo ""
echo -e "  ${BOLD}n8n (Workflow Automation):${NC}"
echo -e "    URL:      ${CYAN}http://${HOST_IP}:${N8N_PORT_FINAL}${NC}"
echo -e "    Create an admin account on first access"

BOOKSTACK_PASS_FINAL=$(grep "^BOOKSTACK_ADMIN_PASSWORD=" "$PROJECT_ROOT/.env" 2>/dev/null | head -1 | sed 's/^[^=]*=//;s/^"//;s/"$//' || true)
BOOKSTACK_USER_FINAL=$(grep "^BOOKSTACK_ADMIN_EMAIL=" "$PROJECT_ROOT/.env" 2>/dev/null | head -1 | sed 's/^[^=]*=//;s/^"//;s/"$//' || true)
if [[ -n "$BOOKSTACK_USER_FINAL" && -n "$BOOKSTACK_PASS_FINAL" ]]; then
    echo ""
    echo -e "  ${BOLD}BookStack Admin:${NC}"
    echo -e "    URL:      ${CYAN}http://${HOST_IP}:8875${NC}"
    echo -e "    Login:    ${BOLD}${BOOKSTACK_USER_FINAL}${NC} / ${YELLOW}${BOOKSTACK_PASS_FINAL}${NC}"
fi

if [[ -n "${ollama_model:-}" ]]; then
    echo ""
    echo -e "  ${BOLD}Ollama Model:${NC}"
    if [[ "$ollama_model_pulled" == "y" ]]; then
        echo -e "    ${ollama_model} — ready"
    else
        echo -e "    ${ollama_model} — ${YELLOW}not yet pulled${NC}"
        echo -e "    docker exec ollama ollama pull ${ollama_model}"
    fi
fi

if $ENABLE_BACKEND; then
    echo ""
    echo -e "  ${BOLD}Ancroo Backend:${NC}"
    echo -e "    URL:      ${CYAN}http://${HOST_IP}:8900${NC}"
    echo -e "    Admin:    ${CYAN}http://${HOST_IP}:8900/admin${NC}"
fi

if $ENABLE_RUNNER; then
    echo ""
    echo -e "  ${BOLD}Ancroo Runner:${NC}"
    echo -e "    URL:      ${CYAN}http://${HOST_IP}:8510${NC}"
    echo -e "    Plugins:  ${CYAN}${PROJECT_ROOT}/data/ancroo-runner/plugins${NC}"
fi

if $ENABLE_EXTENSION; then
    echo ""
    echo -e "  ${BOLD}Ancroo Extension (load in Chrome):${NC}"
    echo "    1. Open chrome://extensions"
    echo "    2. Enable Developer mode"
    echo "    3. Load unpacked → select: ${WEB_DIR}/dist/"
    echo "    4. Set backend URL: http://${HOST_IP}:8900"
fi

if $ENABLE_BACKEND; then
    echo ""
    echo -e "  ${BOLD}Workflows:${NC}"
    echo "    Import example workflows via the admin panel:"
    echo -e "    ${CYAN}http://${HOST_IP}:8900/admin${NC} → Import Workflow"
fi

echo ""
echo -e "  ${BOLD}Manage modules:${NC}"
echo "    ./module.sh list           — available modules"
echo "    ./module.sh urls           — all service URLs"
echo "    ./module.sh status         — running status"
echo "    ./module.sh enable <name>  — add a module"
echo ""
echo -e "  ${BOLD}Optional modules ${YELLOW}(experimental, enable manually)${NC}${BOLD}:${NC}"
echo -e "    SSL:           ${CYAN}./module.sh enable ssl${NC}"
echo -e "    SSO:           ${CYAN}./module.sh enable sso${NC}"

# --- Repeat all warnings at the very end ---
if [[ ${#_fp_warnings[@]} -gt 0 ]]; then
    echo ""
    echo -e "  ${BOLD}${YELLOW}════════════════════════════════════════════════${NC}"
    echo -e "  ${BOLD}${YELLOW}  ⚠  Warnings${NC}"
    echo -e "  ${BOLD}${YELLOW}════════════════════════════════════════════════${NC}"
    for _w in "${_fp_warnings[@]}"; do
        print_warning "$_w"
    done
    echo ""
    print_warning "Check with: docker compose ps"
fi
echo ""
echo -e "  ${BOLD}${GREEN}═══════════════════════════════════════════════════════${NC}"
echo ""
