#!/usr/bin/env bash
# ============================================
# add_admin.sh — Add an admin user to the DB
# ============================================
# Usage:
#   ./scripts/database/add_admin.sh
#   ./scripts/database/add_admin.sh --email admin@example.com --password 'SecurePass123!' --first-name Jean --last-name Dupont
#
# Requires: node (for bcrypt hashing), psql or DATABASE_URL in Back/.env
# ============================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
ENV_FILE="$PROJECT_ROOT/Back/.env"

# ── Colors ──
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

echo -e "${CYAN}${BOLD}╔══════════════════════════════════════════╗${NC}"
echo -e "${CYAN}${BOLD}║   🍽️  Vite & Gourmand — Add Admin User  ║${NC}"
echo -e "${CYAN}${BOLD}╚══════════════════════════════════════════╝${NC}"
echo ""

# ── Load DATABASE_URL from .env ──
if [[ -f "$ENV_FILE" ]]; then
  DATABASE_URL=$(grep '^DATABASE_URL=' "$ENV_FILE" | head -1 | sed 's/^DATABASE_URL=//' | tr -d '"' | tr -d "'")
else
  echo -e "${RED}Error: Back/.env file not found.${NC}"
  echo "Please create it with a DATABASE_URL variable."
  exit 1
fi

if [[ -z "${DATABASE_URL:-}" ]]; then
  echo -e "${RED}Error: DATABASE_URL not found in .env${NC}"
  exit 1
fi

# ── Parse CLI args or prompt interactively ──
EMAIL=""
PASSWORD=""
FIRST_NAME=""
LAST_NAME=""
PHONE=""
CITY=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --email)      EMAIL="$2";      shift 2 ;;
    --password)   PASSWORD="$2";   shift 2 ;;
    --first-name) FIRST_NAME="$2"; shift 2 ;;
    --last-name)  LAST_NAME="$2";  shift 2 ;;
    --phone)      PHONE="$2";      shift 2 ;;
    --city)       CITY="$2";       shift 2 ;;
    -h|--help)
      echo "Usage: $0 [options]"
      echo ""
      echo "Options:"
      echo "  --email       Email address (required)"
      echo "  --password    Password (required, min 8 chars)"
      echo "  --first-name  First name (required)"
      echo "  --last-name   Last name (optional)"
      echo "  --phone       Phone number (optional)"
      echo "  --city        City (optional)"
      echo "  -h, --help    Show this help"
      exit 0
      ;;
    *)
      echo -e "${RED}Unknown option: $1${NC}"
      exit 1
      ;;
  esac
done

# Interactive prompts for missing fields
if [[ -z "$EMAIL" ]]; then
  read -rp "$(echo -e "${YELLOW}📧 Email address: ${NC}")" EMAIL
fi
if [[ -z "$FIRST_NAME" ]]; then
  read -rp "$(echo -e "${YELLOW}👤 First name: ${NC}")" FIRST_NAME
fi
if [[ -z "$LAST_NAME" ]]; then
  read -rp "$(echo -e "${YELLOW}👤 Last name (optional, press Enter to skip): ${NC}")" LAST_NAME
fi
if [[ -z "$PASSWORD" ]]; then
  read -srp "$(echo -e "${YELLOW}🔑 Password (min 8 chars): ${NC}")" PASSWORD
  echo ""
fi

# ── Validate inputs ──
if [[ -z "$EMAIL" || -z "$FIRST_NAME" || -z "$PASSWORD" ]]; then
  echo -e "${RED}Error: email, first name, and password are required.${NC}"
  exit 1
fi

if [[ ${#PASSWORD} -lt 8 ]]; then
  echo -e "${RED}Error: password must be at least 8 characters.${NC}"
  exit 1
fi

echo ""
echo -e "${CYAN}Hashing password with bcrypt (12 rounds)...${NC}"

# ── Hash password using Node.js (bcrypt, 12 rounds — same as backend) ──
HASHED_PASSWORD=$(node -e "
  const bcrypt = require('bcrypt');
  bcrypt.hash('${PASSWORD//\'/\\\'}', 12).then(h => process.stdout.write(h));
" 2>/dev/null) || {
  # Fallback: try from the Back directory where bcrypt is installed
  HASHED_PASSWORD=$(cd "$PROJECT_ROOT/Back" && node -e "
    const bcrypt = require('bcrypt');
    bcrypt.hash('${PASSWORD//\'/\\\'}', 12).then(h => process.stdout.write(h));
  " 2>/dev/null) || {
    echo -e "${RED}Error: Could not hash password. Make sure bcrypt is installed.${NC}"
    echo "Run: cd Back && npm install"
    exit 1
  }
}

echo -e "${GREEN}✓ Password hashed successfully${NC}"

# ── Ensure 'admin' role exists and get its ID ──
echo -e "${CYAN}Ensuring 'admin' role exists...${NC}"

ROLE_SQL="
INSERT INTO \"Role\" (name, description)
VALUES ('admin', 'Administrator with full management access')
ON CONFLICT (name) DO NOTHING;

SELECT id FROM \"Role\" WHERE name = 'admin';
"

ROLE_ID=$(psql "$DATABASE_URL" -t -A -c "$ROLE_SQL" 2>/dev/null | tail -1)

if [[ -z "$ROLE_ID" ]]; then
  echo -e "${RED}Error: Could not find or create 'admin' role.${NC}"
  exit 1
fi

echo -e "${GREEN}✓ Admin role ID: ${ROLE_ID}${NC}"

# ── Build the SQL for escaping ──
LAST_NAME_SQL="NULL"
if [[ -n "$LAST_NAME" ]]; then
  LAST_NAME_SQL="'${LAST_NAME//\'/\'\'}'"
fi

PHONE_SQL="NULL"
if [[ -n "$PHONE" ]]; then
  PHONE_SQL="'${PHONE//\'/\'\'}'"
fi

CITY_SQL="NULL"
if [[ -n "$CITY" ]]; then
  CITY_SQL="'${CITY//\'/\'\'}'"
fi

# ── Insert admin user ──
echo -e "${CYAN}Creating admin user...${NC}"

INSERT_SQL="
INSERT INTO \"User\" (
  email,
  password,
  first_name,
  last_name,
  phone_number,
  city,
  country,
  role_id,
  is_active,
  is_email_verified,
  gdpr_consent,
  gdpr_consent_date,
  created_at,
  updated_at
) VALUES (
  '${EMAIL//\'/\'\'}',
  '${HASHED_PASSWORD//\'/\'\'}',
  '${FIRST_NAME//\'/\'\'}',
  ${LAST_NAME_SQL},
  ${PHONE_SQL},
  ${CITY_SQL},
  'France',
  ${ROLE_ID},
  true,
  true,
  true,
  NOW(),
  NOW(),
  NOW()
)
ON CONFLICT (email) DO UPDATE SET
  role_id = ${ROLE_ID},
  password = '${HASHED_PASSWORD//\'/\'\'}',
  is_active = true,
  updated_at = NOW()
RETURNING id, email, first_name, role_id;
"

RESULT=$(psql "$DATABASE_URL" -t -A -c "$INSERT_SQL" 2>&1)

if [[ $? -ne 0 ]]; then
  echo -e "${RED}Error inserting user:${NC}"
  echo "$RESULT"
  exit 1
fi

echo ""
echo -e "${GREEN}${BOLD}╔══════════════════════════════════════════╗${NC}"
echo -e "${GREEN}${BOLD}║         ✅  Admin user created!          ║${NC}"
echo -e "${GREEN}${BOLD}╚══════════════════════════════════════════╝${NC}"
echo ""
echo -e "  ${BOLD}Email:${NC}      $EMAIL"
echo -e "  ${BOLD}Name:${NC}       $FIRST_NAME ${LAST_NAME:-}"
echo -e "  ${BOLD}Role:${NC}       admin (ID: $ROLE_ID)"
echo -e "  ${BOLD}DB Result:${NC}  $RESULT"
echo ""
echo -e "${YELLOW}You can now log in at /portal with these credentials.${NC}"
