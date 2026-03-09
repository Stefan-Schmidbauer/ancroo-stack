#!/bin/bash
# Speaches Module — Post-Enable Script
# Pre-downloads the Whisper model so that the first transcription request
# does not fail with 404 ("model not installed locally").
#
# Reads ANCROO_WHISPER_MODEL from .env (set by the ancroo module).
# Falls back to DEFAULT_MODEL if no override is configured.
#
# Supports non-interactive mode:
#   SKIP_CONFIRM=1 — skip interactive prompts
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

DEFAULT_MODEL="Systran/faster-whisper-large-v3"

safe_source_env "$ENV_FILE"

# Determine which model to pre-download
MODEL="${ANCROO_WHISPER_MODEL:-$DEFAULT_MODEL}"

# ─── Resolve container address ────────────────────────────
SP_HOST=$(docker inspect speaches --format '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' 2>/dev/null || true)
if [[ -z "$SP_HOST" ]]; then
    print_warning "Speaches container not found — model pre-download skipped"
    return 0 2>/dev/null || exit 0
fi
SP_URL="http://${SP_HOST}:8000"

# ─── Wait for Speaches API ───────────────────────────────
MAX_WAIT=120
WAITED=0
while true; do
    if curl -sf "${SP_URL}/health" >/dev/null 2>&1; then
        break
    fi
    if [[ $WAITED -ge $MAX_WAIT ]]; then
        print_warning "Speaches API not ready after ${MAX_WAIT}s — model pre-download skipped"
        return 0 2>/dev/null || exit 0
    fi
    sleep 5
    WAITED=$((WAITED + 5))
done

# ─── Check if model is already installed ─────────────────
MODELS_JSON=$(curl -sf "${SP_URL}/v1/models" 2>/dev/null || echo '{"data":[]}')
if echo "$MODELS_JSON" | python3 -c "
import sys, json
data = json.load(sys.stdin)
models = [m.get('id','') for m in data.get('data', [])]
sys.exit(0 if '$MODEL' in models else 1)
" 2>/dev/null; then
    print_info "Whisper model already installed: $MODEL"
    return 0 2>/dev/null || exit 0
fi

# ─── Ask before downloading ───────────────────────────────
if [[ -z "${SKIP_CONFIRM:-}" ]] && [[ -z "${ANCROO_NONINTERACTIVE:-}" ]]; then
    echo ""
    echo -ne "  Download Whisper model ${MODEL}? [J/n]: "
    read -r dl_confirm
    if [[ "$dl_confirm" =~ ^[nN]$ ]]; then
        print_info "Skipped — download later: curl -X POST http://<HOST_IP>:${SPEACHES_PORT:-8100}/v1/models/${MODEL//\//%2F}"
        return 0 2>/dev/null || exit 0
    fi
fi

print_step "Pre-downloading Whisper model: $MODEL"

# URL-encode the model name (slashes → %2F)
MODEL_ENCODED="${MODEL//\//%2F}"

RESPONSE=$(curl -sf -X POST "${SP_URL}/v1/models/${MODEL_ENCODED}" 2>&1) || {
    print_warning "Model download failed — transcription will attempt download on first use"
    print_info "You can download manually: curl -X POST http://<HOST_IP>:${SPEACHES_PORT:-8100}/v1/models/${MODEL_ENCODED}"
    return 0 2>/dev/null || exit 0
}

# Verify model is now available
MODELS_AFTER=$(curl -sf "${SP_URL}/v1/models" 2>/dev/null || echo '{"data":[]}')
if echo "$MODELS_AFTER" | python3 -c "
import sys, json
data = json.load(sys.stdin)
models = [m.get('id','') for m in data.get('data', [])]
sys.exit(0 if '$MODEL' in models else 1)
" 2>/dev/null; then
    print_success "Whisper model ready: $MODEL"
else
    print_warning "Model download returned OK but model not listed — check speaches logs"
fi
