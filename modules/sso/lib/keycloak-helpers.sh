#!/bin/bash
# Keycloak Helper Functions — shared by SSO module scripts
#
# Requires: common.sh (print_error) must be loaded before sourcing this file.

# Get the Keycloak REST API URL via container IP inspection.
# Keycloak has no host port mapping — only reachable via Docker network.
get_keycloak_url() {
    local ip
    ip=$(docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' keycloak 2>/dev/null)
    if [[ -z "$ip" ]]; then
        print_error "Keycloak Container nicht gefunden oder nicht gestartet"
        return 1
    fi
    echo "http://${ip}:8080"
}
