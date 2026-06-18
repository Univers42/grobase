#!/usr/bin/env bash
# **************************************************************************** #
#                                                                              #
#    postman-cli.sh - Official Postman CLI Integration                        #
#                                                                              #
#    The Postman CLI is the official replacement for Newman with:             #
#    - Direct cloud sync                                                       #
#    - API key authentication                                                  #
#    - Collection runs with results pushed to Postman                         #
#    - CI/CD integration                                                       #
#                                                                              #
# **************************************************************************** #

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
POSTMAN_DIR="$PROJECT_ROOT/backend/postman"
REPORTS_DIR="$PROJECT_ROOT/reports"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

# Default values
BASE_URL="${API_URL:-http://localhost:3000/api}"

print_header() {
    echo -e "${CYAN}"
    echo "╔══════════════════════════════════════════════════════════════╗"
    echo "║           📮 Postman CLI - Official Test Runner              ║"
    echo "╚══════════════════════════════════════════════════════════════╝"
    echo -e "${NC}"
}

print_usage() {
    cat << 'EOF'
Usage: postman-cli.sh [COMMAND] [OPTIONS]

Official Postman CLI integration for running collections.

COMMANDS:
    install             Install Postman CLI
    login               Login to Postman (opens browser)
    run COLLECTION_ID   Run a collection from Postman Cloud
    run-local FILE      Run a local collection file
    list                List your collections
    help                Show this help

OPTIONS:
    -e, --environment ID    Use environment from Postman Cloud
    -k, --api-key KEY       Postman API key (or set POSTMAN_API_KEY env)
    --ci                    CI mode (no interactive prompts)
    -r, --reporters         Reporter types (cli,json,junit)

EXAMPLES:
    # Install Postman CLI
    ./postman-cli.sh install

    # Login to Postman
    ./postman-cli.sh login

    # Run collection from cloud (synced with UI)
    ./postman-cli.sh run 12345678-abcd-1234-abcd-123456789012

    # Run local collection file
    ./postman-cli.sh run-local backend/postman/auth.json

    # Run in CI with API key
    POSTMAN_API_KEY=xxx ./postman-cli.sh run COLLECTION_ID --ci

SETUP FOR SYNC WITH UI:
    1. Install: ./postman-cli.sh install
    2. Login:   ./postman-cli.sh login
    3. Create collections in Postman UI
    4. Get collection ID from UI (Info tab)
    5. Run:     ./postman-cli.sh run YOUR_COLLECTION_ID

    Changes in UI sync automatically!

EOF
}

check_postman_cli() {
    if ! command -v postman &> /dev/null; then
        echo -e "${YELLOW}Postman CLI not found.${NC}"
        echo ""
        echo "Install with:"
        echo "  ./postman-cli.sh install"
        echo ""
        echo "Or manually:"
        echo "  curl -o- https://dl-cli.pstmn.io/install/linux64.sh | sh"
        exit 1
    fi
}

install_postman_cli() {
    echo -e "${BLUE}▶ Installing Postman CLI...${NC}"
    
    if command -v postman &> /dev/null; then
        echo -e "${GREEN}✓ Postman CLI already installed${NC}"
        postman --version
        return 0
    fi
    
    # Detect OS and install
    case "$(uname -s)" in
        Linux*)
            echo "Installing for Linux..."
            curl -o- "https://dl-cli.pstmn.io/install/linux64.sh" | sh
            ;;
        Darwin*)
            echo "Installing for macOS..."
            curl -o- "https://dl-cli.pstmn.io/install/osx_64.sh" | sh
            ;;
        MINGW*|MSYS*|CYGWIN*)
            echo "For Windows, download from:"
            echo "https://dl-cli.pstmn.io/download/latest/win64"
            exit 1
            ;;
        *)
            echo -e "${RED}Unsupported OS. Visit: https://learning.postman.com/docs/postman-cli/postman-cli-installation/${NC}"
            exit 1
            ;;
    esac
    
    echo -e "${GREEN}✓ Postman CLI installed${NC}"
    postman --version
}

postman_login() {
    check_postman_cli
    echo -e "${BLUE}▶ Logging into Postman...${NC}"
    echo "This will open your browser for authentication."
    echo ""
    postman login
    echo -e "${GREEN}✓ Logged in successfully${NC}"
}

run_collection_cloud() {
    local collection_id="$1"
    shift
    
    check_postman_cli
    
    if [[ -z "$collection_id" ]]; then
        echo -e "${RED}Error: Collection ID required${NC}"
        echo "Find it in Postman UI: Collection → Info tab"
        exit 1
    fi
    
    echo -e "${BLUE}▶ Running collection: ${collection_id}${NC}"
    
    local cmd="postman collection run $collection_id"
    
    # Add environment if specified
    if [[ -n "$POSTMAN_ENV_ID" ]]; then
        cmd="$cmd -e $POSTMAN_ENV_ID"
    fi
    
    # Add global variables
    cmd="$cmd --global-var baseUrl=$BASE_URL"
    
    # Parse additional options
    while [[ $# -gt 0 ]]; do
        case "$1" in
            -e|--environment) cmd="$cmd -e $2"; shift 2 ;;
            --ci) cmd="$cmd --ci"; shift ;;
            -r|--reporters) cmd="$cmd --reporters $2"; shift 2 ;;
            *) shift ;;
        esac
    done
    
    echo -e "${CYAN}$ $cmd${NC}"
    eval "$cmd"
    
    echo -e "${GREEN}✓ Collection run complete${NC}"
    echo -e "${BLUE}Results synced to Postman Cloud!${NC}"
}

run_collection_local() {
    local file="$1"
    shift
    
    check_postman_cli
    
    if [[ ! -f "$file" ]]; then
        echo -e "${RED}Error: File not found: $file${NC}"
        exit 1
    fi
    
    echo -e "${BLUE}▶ Running local collection: ${file}${NC}"
    
    local cmd="postman collection run $file"
    cmd="$cmd --global-var baseUrl=$BASE_URL"
    
    # Add local environment file (localhost)
    local env_file="$POSTMAN_DIR/env.local.json"
    if [[ -f "$env_file" ]]; then
        cmd="$cmd -e $env_file"
    fi
    
    echo -e "${CYAN}$ $cmd${NC}"
    eval "$cmd"
}

list_collections() {
    echo -e "${YELLOW}Note: Postman CLI doesn't support listing collections directly.${NC}"
    echo ""
    echo "To see your collections:"
    echo "  1. Open Postman UI or https://go.postman.co"
    echo "  2. Your collections are in the sidebar"
    echo "  3. Click Info (ℹ️) to get Collection ID"
    echo ""
    echo "Local collections in this repo:"
    find "$POSTMAN_DIR" -name "*.json" -not -name "env.*" | while read -r file; do
        echo "  - $(basename "$file" .json)"
    done
}

# Parse command
COMMAND="${1:-help}"
shift 2>/dev/null || true

print_header

case "$COMMAND" in
    install)
        install_postman_cli
        ;;
    login)
        postman_login
        ;;
    run)
        run_collection_cloud "$@"
        ;;
    run-local)
        run_collection_local "$@"
        ;;
    list)
        list_collections
        ;;
    help|--help|-h)
        print_usage
        ;;
    *)
        echo -e "${RED}Unknown command: $COMMAND${NC}"
        print_usage
        exit 1
        ;;
esac
