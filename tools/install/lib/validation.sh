#!/bin/bash
# validation.sh — System checks for ancroo-stack installation

check_docker_installed() {
    if ! command -v docker &>/dev/null; then
        print_error "Docker is not installed"
        print_info "Install: https://docs.docker.com/engine/install/"
        return 1
    fi
    local version
    version=$(docker --version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1)
    print_success "Docker $version"
}

check_docker_compose_installed() {
    if ! docker compose version &>/dev/null; then
        print_error "Docker Compose plugin is not installed"
        return 1
    fi
    local version
    version=$(docker compose version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1)
    print_success "Docker Compose $version"
}

check_docker_running() {
    if ! docker info &>/dev/null; then
        print_error "Docker daemon is not running"
        print_info "Start with: sudo systemctl start docker"
        return 1
    fi
    print_success "Docker daemon running"
}

check_docker_permissions() {
    if ! docker ps &>/dev/null; then
        print_error "No Docker permission for user $(whoami)"
        print_info "Fix: sudo usermod -aG docker $(whoami) && newgrp docker"
        return 1
    fi
}

detect_docker_gid() {
    local gid
    gid=$(getent group docker 2>/dev/null | cut -d: -f3)
    if [[ -z "$gid" ]]; then
        gid=$(stat -c '%g' /var/run/docker.sock 2>/dev/null)
    fi
    echo "${gid:-999}"
}

check_port_available() {
    local port="$1"
    if command -v ss &>/dev/null; then
        ss -tlnp 2>/dev/null | grep -qE ":${port}(\s|$)" && return 1
    elif command -v netstat &>/dev/null; then
        netstat -tlnp 2>/dev/null | grep -qE ":${port}(\s|$)" && return 1
    fi
    return 0
}

check_disk_space() {
    local available_gb
    available_gb=$(df -BG "$PROJECT_ROOT" 2>/dev/null | awk 'NR==2 {print $4}' | tr -d 'G')
    if [[ -n "$available_gb" ]] && [[ "$available_gb" -lt 10 ]]; then
        print_warning "Only ${available_gb}GB free disk space (recommended: 10GB+)"
        return 1
    fi
    print_success "Disk space: ${available_gb}GB free"
}

check_existing_installation() {
    if [[ -f "$PROJECT_ROOT/.env" ]]; then
        if [[ "${ANCROO_FORCE_REINSTALL:-}" == "1" ]]; then
            print_warning "Existing installation found — overwriting (ANCROO_FORCE_REINSTALL=1)"
            return 0
        else
            print_info "Existing installation found (.env exists)"
            return 1
        fi
    fi
    return 0
}

run_preflight_checks() {
    print_step "Pre-Flight Checks"

    local failed=0
    check_docker_installed || failed=$((failed + 1))
    check_docker_compose_installed || failed=$((failed + 1))
    check_docker_running || failed=$((failed + 1))
    check_docker_permissions || failed=$((failed + 1))
    check_disk_space || true

    # Check critical ports
    local blocked_ports=()
    for port in 80 8080 11434; do
        if ! check_port_available "$port"; then
            blocked_ports+=("$port")
            print_warning "Port $port is in use"
        fi
    done

    if [[ $failed -gt 0 ]]; then
        echo ""
        print_error "$failed check(s) failed. Please fix and retry."
        exit 1
    fi

    if [[ ${#blocked_ports[@]} -gt 0 ]]; then
        echo ""
        print_warning "Ports in use: ${blocked_ports[*]}"
        print_info "An existing installation or service may be blocking these ports."
    fi

    print_success "All checks passed"
}
