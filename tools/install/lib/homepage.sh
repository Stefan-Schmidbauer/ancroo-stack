#!/bin/bash
# homepage.sh — Homepage dashboard configuration helpers

# Load module.env and export variables
# Usage: load_module_env <module_name>
load_module_env() {
    local module="$1"
    local env_file="$PROJECT_ROOT/modules/$module/module.env"

    if [[ -f "$env_file" ]]; then
        # Source and export each variable
        while IFS='=' read -r key value; do
            # Skip comments and empty lines
            [[ "$key" =~ ^#.*$ || -z "$key" ]] && continue
            # Remove quotes from value
            value="${value%\"}"
            value="${value#\"}"
            # Export only if not already set
            if [[ -z "${!key:-}" ]]; then
                export "$key=$value"
            fi
        done < "$env_file"
    fi
}

# Build services.yaml from core + enabled modules
# Usage: build_homepage_services
build_homepage_services() {
    local homepage_dir="$PROJECT_ROOT/data/homepage"
    local output_file="$homepage_dir/services.yaml"
    local temp_file
    temp_file=$(mktemp)

    # Read enabled modules
    local enabled_modules=""
    if [[ -f "$PROJECT_ROOT/.env" ]]; then
        enabled_modules=$(grep '^ENABLED_MODULES=' "$PROJECT_ROOT/.env" | cut -d= -f2 | tr -d '"')
    fi

    # Load all module.env files first (for variable defaults)
    for module in $enabled_modules; do
        load_module_env "$module"
    done

    # Start with YAML header
    echo "---" > "$temp_file"

    # Always include core services
    local core_snippet="$PROJECT_ROOT/tools/config/homepage/homepage.yml"
    if [[ -f "$core_snippet" ]]; then
        # Skip comment lines, substitute variables, append
        grep -v '^#' "$core_snippet" | envsubst >> "$temp_file"
    fi

    # Add enabled modules
    for module in $enabled_modules; do
        local module_snippet="$PROJECT_ROOT/modules/$module/homepage.yml"
        if [[ -f "$module_snippet" ]]; then
            echo "" >> "$temp_file"
            grep -v '^#' "$module_snippet" | envsubst >> "$temp_file"
        fi
    done

    # Write to final location
    mkdir -p "$homepage_dir"
    mv "$temp_file" "$output_file"
    chmod 644 "$output_file"
}

# Create static homepage config files (settings, docker, widgets, bookmarks)
# Usage: create_homepage_static_configs
create_homepage_static_configs() {
    local homepage_dir="$PROJECT_ROOT/data/homepage"
    mkdir -p "$homepage_dir"

    # settings.yaml
    cat > "$homepage_dir/settings.yaml" << 'EOF'
---
title: ancroo-stack
theme: dark
color: slate
headerStyle: clean
statusStyle: dot
layout:
  AI Tools:
    style: column
    columns: 1
  Knowledge:
    style: column
    columns: 1
  Automation:
    style: column
    columns: 2
  Speech:
    style: column
    columns: 3
  Administration:
    style: row
    columns: 5
EOF

    # docker.yaml
    cat > "$homepage_dir/docker.yaml" << 'EOF'
---
local:
  socket: /var/run/docker.sock
EOF

    # widgets.yaml (empty for now)
    cat > "$homepage_dir/widgets.yaml" << 'EOF'
---
EOF

    # bookmarks.yaml
    cat > "$homepage_dir/bookmarks.yaml" << 'EOF'
---
- Links:
    - Ollama Models:
        - icon: sh-ollama
          href: https://ollama.com/library
    - Open WebUI Docs:
        - icon: sh-open-webui
          href: https://docs.openwebui.com
EOF
}

# Full homepage setup (called by install.sh)
# Usage: setup_homepage
setup_homepage() {
    # Export HOST_IP for envsubst
    export HOST_IP="${DETECTED_HOST_IP:-localhost}"

    create_homepage_static_configs
    build_homepage_services

    print_success "Homepage configured"
}
