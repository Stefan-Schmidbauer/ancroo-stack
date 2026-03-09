#!/bin/bash
# ancroo-stack — Complete Uninstall
# Entfernt alle Container, Daten und Konfiguration
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

# Colors
RED='\033[0;31m'
YELLOW='\033[1;33m'
GREEN='\033[0;32m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

# ─── Dry-run mode ──────────────────────────────────────────
DRY_RUN=false
if [[ "${1:-}" == "--dry-run" ]]; then
    DRY_RUN=true
fi

echo ""
echo -e "  ${RED}${BOLD}════════════════════════════════════════${NC}"
echo -e "  ${RED}${BOLD}  ancroo-stack — Vollstaendige Deinstallation${NC}"
echo -e "  ${RED}${BOLD}════════════════════════════════════════${NC}"

if $DRY_RUN; then
    echo ""
    echo -e "  ${CYAN}${BOLD}  [DRY-RUN] Keine Aenderungen — nur Vorschau${NC}"
fi

echo ""
echo -e "  ${YELLOW}Dies wird folgende Komponenten entfernen:${NC}"
echo "    - Alle Docker Container"
echo "    - PostgreSQL Datenbank (User, Chats, RAG-Dokumente)"
echo "    - Open WebUI Konfiguration"
echo "    - Homepage Einstellungen"
echo "    - Logs"
echo ""

if ! $DRY_RUN; then
    echo -ne "  ${BOLD}Deinstallation starten? [j/N]: ${NC}"
    read -r confirm

    if [[ ! "$confirm" =~ ^[jJyY]$ ]]; then
        echo ""
        echo -e "  ${GREEN}Abgebrochen.${NC}"
        echo ""
        exit 0
    fi
fi

echo ""
# Model directories to preserve (LLM + Whisper/STT)
MODEL_DIRS=("ollama" "speaches" "whisper-server" "whisper-rocm")

if $DRY_RUN; then
    remove_models="j"
    remove_env="j"
    remove_images="j"
    echo -e "  ${CYAN}→${NC} [DRY-RUN] Alle Optionen werden fuer die Vorschau angenommen"
else
    echo -ne "  ${BOLD}Modelle ebenfalls loeschen? (LLM + Whisper, evtl. mehrere GB) [j/N]: ${NC}"
    read -r remove_models

    echo ""
    echo -ne "  ${BOLD}.env Konfiguration ebenfalls loeschen? [j/N]: ${NC}"
    read -r remove_env

    echo ""
    echo -ne "  ${BOLD}Docker-Images ebenfalls entfernen? [j/N]: ${NC}"
    read -r remove_images
fi

echo ""

# All known container names across base services and modules
KNOWN_CONTAINERS=(
    postgres ollama open-webui homepage
    n8n adminer valkey
    speaches whisper-rocm
    bookstack bookstack-db
    ancroo-backend service-tools
    traefik keycloak oauth2-proxy acme
    activepieces
)

# 1. Stop and remove containers (including stopped ones)
echo -e "  [1/4] Container stoppen..."
if $DRY_RUN; then
    # Check compose-managed containers
    if docker compose ps -a -q 2>/dev/null | grep -q .; then
        echo -e "  ${CYAN}→${NC} [DRY-RUN] Wuerde Container via docker compose down entfernen"
    fi
    # Check for known containers (fallback)
    for name in "${KNOWN_CONTAINERS[@]}"; do
        if docker container inspect "$name" >/dev/null 2>&1; then
            echo -e "  ${CYAN}→${NC} [DRY-RUN] Wuerde Container entfernen: $name"
        fi
    done
else
    # Try compose down first (works when .env + COMPOSE_FILE are intact)
    if docker compose down -v --remove-orphans 2>&1; then
        echo -e "  ${GREEN}✓${NC} docker compose down erfolgreich"
    else
        echo -e "  ${YELLOW}⚠${NC}  docker compose down fehlgeschlagen — verwende Fallback"
    fi

    # Fallback: force-remove all known containers by name
    # Catches orphans and containers missed by compose down
    removed=0
    for name in "${KNOWN_CONTAINERS[@]}"; do
        if docker container inspect "$name" >/dev/null 2>&1; then
            docker rm -f "$name" >/dev/null 2>&1 && ((removed++)) || true
        fi
    done
    if ((removed > 0)); then
        echo -e "  ${GREEN}✓${NC} $removed Container per Fallback entfernt"
    fi

    # Remove docker network
    docker network rm ai-network 2>/dev/null && \
        echo -e "  ${GREEN}✓${NC} Netzwerk ai-network entfernt" || true

    # Verify no known containers remain
    remaining=()
    for name in "${KNOWN_CONTAINERS[@]}"; do
        if docker container inspect "$name" >/dev/null 2>&1; then
            remaining+=("$name")
        fi
    done
    if ((${#remaining[@]} > 0)); then
        echo -e "  ${RED}✗${NC} Container konnten nicht entfernt werden: ${remaining[*]}"
    else
        echo -e "  ${GREEN}✓${NC} Alle Container entfernt"
    fi
fi

# 2. Remove data directories
echo -e "  [2/4] Datenverzeichnisse loeschen..."
if [[ -d "data" ]]; then
    # Helper: check if a directory name is a model directory
    is_model_dir() { local n; for n in "${MODEL_DIRS[@]}"; do [[ "$1" == "$n" ]] && return 0; done; return 1; }

    if $DRY_RUN; then
        if [[ "$remove_models" =~ ^[jJyY]$ ]]; then
            echo -e "  ${CYAN}→${NC} [DRY-RUN] Wuerde loeschen: data/ (inkl. Modelle)"
            { du -sh data/ 2>/dev/null || true; } | while read -r size dir; do echo "    Groesse: $size"; done
        else
            echo -e "  ${CYAN}→${NC} [DRY-RUN] Wuerde loeschen: data/ (ohne Modelle)"
            for dir in data/*/; do
                is_model_dir "$(basename "$dir")" && continue
                { du -sh "$dir" 2>/dev/null || true; } | while read -r size d; do echo "    $d ($size)"; done
            done
            echo -e "  ${CYAN}→${NC} [DRY-RUN] Modelle beibehalten:"
            for dir in data/*/; do
                is_model_dir "$(basename "$dir")" || continue
                { du -sh "$dir" 2>/dev/null || true; } | while read -r size d; do echo "    $d ($size)"; done
            done
        fi
    else
        # Safety check: warn if containers are still running (data might be locked)
        running_containers=()
        for name in "${KNOWN_CONTAINERS[@]}"; do
            if docker inspect -f '{{.State.Running}}' "$name" 2>/dev/null | grep -q true; then
                running_containers+=("$name")
            fi
        done
        if ((${#running_containers[@]} > 0)); then
            echo -e "  ${RED}✗${NC} Container laufen noch: ${running_containers[*]}"
            echo -e "    Daten koennten gesperrt sein — Loeschung wird trotzdem versucht"
        fi

        # Use sudo for data dir — some subdirectories are owned by container UIDs
        # (postgres:999, valkey:999, bookstack-db) and need elevated privileges.
        del_failed=false
        if [[ "$remove_models" =~ ^[jJyY]$ ]]; then
            if ! sudo rm -rf data; then
                rm -rf data 2>/dev/null || true
            fi
            if [[ -d "data" ]]; then
                del_failed=true
                echo -e "  ${RED}✗${NC} Datenverzeichnisse konnten nicht vollstaendig geloescht werden"
                echo -e "    Versuche manuell: sudo rm -rf $(pwd)/data"
            else
                echo -e "  ${GREEN}✓${NC} Datenverzeichnisse geloescht (inkl. Modelle)"
            fi
        else
            # Delete everything in data/ except model directories
            for dir in data/*/; do
                [[ -d "$dir" ]] || continue
                is_model_dir "$(basename "$dir")" && continue
                if ! sudo rm -rf "$dir" 2>/dev/null; then
                    rm -rf "$dir" 2>/dev/null || true
                fi
                if [[ -d "$dir" ]]; then
                    echo -e "  ${RED}✗${NC} Konnte nicht loeschen: $dir"
                    del_failed=true
                fi
            done
            # Remove any files directly in data/ (not subdirectories)
            find data -maxdepth 1 -type f -exec rm -f {} + 2>/dev/null || true

            # Verify: list what remains vs what was deleted
            remaining_dirs=()
            for dir in data/*/; do
                [[ -d "$dir" ]] || continue
                remaining_dirs+=("$(basename "$dir")")
            done

            if $del_failed; then
                echo -e "  ${RED}✗${NC} Einige Datenverzeichnisse konnten nicht geloescht werden"
                echo -e "    Verbleibend: ${remaining_dirs[*]}"
                echo -e "    Versuche manuell: sudo rm -rf $(pwd)/data/<dir>"
            else
                if ((${#remaining_dirs[@]} > 0)); then
                    echo -e "  ${GREEN}✓${NC} Datenverzeichnisse geloescht (Modelle beibehalten: ${remaining_dirs[*]})"
                else
                    echo -e "  ${GREEN}✓${NC} Datenverzeichnisse geloescht"
                fi
            fi
        fi
    fi
else
    echo -e "  ${GREEN}✓${NC} Keine Datenverzeichnisse vorhanden"
fi

# 3. Remove configuration
echo -e "  [3/4] Konfiguration loeschen..."
if $DRY_RUN; then
    if [[ "$remove_env" =~ ^[jJyY]$ ]]; then
        echo -e "  ${CYAN}→${NC} [DRY-RUN] Wuerde loeschen: .env"
    else
        echo -e "  ${CYAN}→${NC} [DRY-RUN] .env beibehalten"
    fi
    echo -e "  ${CYAN}→${NC} [DRY-RUN] Wuerde loeschen: logs/"
else
    if [[ "$remove_env" =~ ^[jJyY]$ ]]; then
        rm -f .env 2>/dev/null || true
        echo -e "  ${GREEN}✓${NC} .env geloescht"
    else
        echo -e "  ${GREEN}✓${NC} .env beibehalten"
    fi
    rm -rf logs 2>/dev/null || true
    echo -e "  ${GREEN}✓${NC} Logs geloescht"
fi

# 4. Optionally remove Docker images
if [[ "$remove_images" =~ ^[jJyY]$ ]]; then
    echo -e "  [4/4] Docker-Images entfernen..."
    # Image name prefixes to match (covers all tags/versions)
    KNOWN_IMAGE_PREFIXES=(
        "ollama/ollama"
        "ghcr.io/open-webui/open-webui"
        "pgvector/pgvector"
        "ghcr.io/gethomepage/homepage"
        "docker.n8n.io/n8nio/n8n" "n8nio/n8n"
        "ghcr.io/ancroo/ancroo-backend"
        "lscr.io/linuxserver/bookstack"
        "mariadb"
        "valkey/valkey"
        "ghcr.io/speaches-ai/speaches"
        "traefik"
        "neilpang/acme.sh"
        "quay.io/keycloak/keycloak"
        "quay.io/oauth2-proxy/oauth2-proxy"
        "adminer"
    )

    # Find all matching images (any tag)
    matching_images=()
    while IFS= read -r img; do
        [[ -z "$img" ]] && continue
        for prefix in "${KNOWN_IMAGE_PREFIXES[@]}"; do
            if [[ "$img" == "$prefix:"* ]]; then
                matching_images+=("$img")
                break
            fi
        done
    done < <(docker images --format '{{.Repository}}:{{.Tag}}' 2>/dev/null)

    if $DRY_RUN; then
        if ((${#matching_images[@]} > 0)); then
            echo -e "  ${CYAN}→${NC} [DRY-RUN] Wuerde folgende Images entfernen:"
            for img in "${matching_images[@]}"; do
                size=$(docker image inspect "$img" --format '{{.Size}}' 2>/dev/null | awk '{printf "%.0f MB", $1/1024/1024}')
                echo "    $img ($size)"
            done
        else
            echo -e "  ${CYAN}→${NC} [DRY-RUN] Keine Stack-Images vorhanden"
        fi
    else
        for img in "${matching_images[@]}"; do
            docker rmi "$img" 2>/dev/null || true
        done
        echo -e "  ${GREEN}✓${NC} ${#matching_images[@]} Docker-Images entfernt"
    fi
else
    echo -e "  [4/4] Docker-Images behalten"
fi

echo ""
if $DRY_RUN; then
    echo -e "  ${CYAN}${BOLD}════════════════════════════════════════${NC}"
    echo -e "  ${CYAN}${BOLD}  Dry-Run abgeschlossen — nichts geaendert${NC}"
    echo -e "  ${CYAN}${BOLD}════════════════════════════════════════${NC}"
    echo ""
    echo "  Tatsaechlich deinstallieren mit:"
    echo "    ./uninstall.sh"
else
    echo -e "  ${GREEN}${BOLD}════════════════════════════════════════${NC}"
    echo -e "  ${GREEN}${BOLD}  Deinstallation abgeschlossen${NC}"
    echo -e "  ${GREEN}${BOLD}════════════════════════════════════════${NC}"
    echo ""
    echo "  Neu installieren mit:"
    echo "    ./install.sh"
fi
echo ""
