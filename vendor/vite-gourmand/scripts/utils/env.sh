#!/bin/bash
# ============================================
# Utils: Environment Variables Helper
# Usage: make env-show / make env-check
# ============================================
set -e
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$SCRIPT_DIR/lib/common.sh"

print_header "🔧 Environment Variables"

cd "$PROJECT_ROOT"

ACTION="${1:-show}"

case "$ACTION" in
    show)
        log "Environment files found:"
        
        for envfile in .env Back/.env .env.local Back/.env.local; do
            if [ -f "$envfile" ]; then
                echo ""
                log "=== $envfile ==="
                # Show keys but mask values
                while IFS='=' read -r key value || [ -n "$key" ]; do
                    # Skip comments and empty lines
                    [[ "$key" =~ ^#.*$ ]] && continue
                    [[ -z "$key" ]] && continue
                    
                    # Mask sensitive values
                    if [[ "$key" =~ (PASSWORD|SECRET|KEY|TOKEN) ]]; then
                        echo "  $key=***masked***"
                    else
                        # Truncate long values
                        if [ ${#value} -gt 50 ]; then
                            echo "  $key=${value:0:47}..."
                        else
                            echo "  $key=$value"
                        fi
                    fi
                done < "$envfile"
            fi
        done
        ;;
        
    check)
        log "Checking required environment variables..."
        
        REQUIRED=(
            "DATABASE_URL"
            "JWT_SECRET"
            "NODE_ENV"
        )
        
        OPTIONAL=(
            "SUPABASE_URL"
            "SUPABASE_ANON_KEY"
            "MONGODB_URI"
            "UNSPLASH_ACCESS_KEY"
            "PORT"
        )
        
        echo ""
        log "Required:"
        for var in "${REQUIRED[@]}"; do
            if grep -qE "^$var=" .env Back/.env 2>/dev/null; then
                printf "${GREEN}✓${NC} %s is set\n" "$var"
            else
                printf "${RED}✗${NC} %s is missing\n" "$var"
            fi
        done
        
        echo ""
        log "Optional:"
        for var in "${OPTIONAL[@]}"; do
            if grep -qE "^$var=" .env Back/.env 2>/dev/null; then
                printf "${GREEN}✓${NC} %s is set\n" "$var"
            else
                printf "${YELLOW}○${NC} %s is not set\n" "$var"
            fi
        done
        ;;
        
    *)
        log "Usage: env.sh [show|check]"
        exit 1
        ;;
esac
