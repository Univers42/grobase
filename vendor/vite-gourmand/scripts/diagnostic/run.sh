#!/bin/bash
# ============================================
# Run All Diagnostics
# Usage: make diagnostic [CHECK=rgpd|rgaa|docker|code|perf|all]
# ============================================
set -e
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPTS_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
source "$SCRIPTS_DIR/lib/common.sh"

CHECK="${CHECK:-all}"

print_header "🔍 Vite Gourmand Diagnostics"

cd "$PROJECT_ROOT"

run_check() {
    local name="$1"
    local script="$2"
    
    if [ -f "$script" ]; then
        log "Running $name diagnostic..."
        bash "$script" || true
        echo ""
    else
        print_warn "Script not found: $script"
    fi
}

case "$CHECK" in
    rgpd)
        run_check "RGPD" "$SCRIPT_DIR/check_rgpd.sh"
        ;;
    rgaa)
        run_check "RGAA" "$SCRIPT_DIR/check_rgaa.sh"
        ;;
    docker)
        run_check "Docker" "$SCRIPTS_DIR/docker/check_docker.sh"
        ;;
    code)
        run_check "Code Quality" "$SCRIPT_DIR/check_code_quality.sh"
        ;;
    perf)
        run_check "Performance" "$SCRIPT_DIR/check_performance.sh"
        ;;
    all)
        log "Running all diagnostics..."
        echo ""
        run_check "RGPD Compliance" "$SCRIPT_DIR/check_rgpd.sh"
        run_check "RGAA Accessibility" "$SCRIPT_DIR/check_rgaa.sh"
        run_check "Docker Infrastructure" "$SCRIPTS_DIR/docker/check_docker.sh"
        run_check "Code Quality" "$SCRIPT_DIR/check_code_quality.sh"
        run_check "Performance" "$SCRIPT_DIR/check_performance.sh"
        ;;
    *)
        print_error "Unknown check: $CHECK"
        log "Valid options: rgpd, rgaa, docker, code, perf, all"
        exit 1
        ;;
esac

print_ok "Diagnostics completed!"
