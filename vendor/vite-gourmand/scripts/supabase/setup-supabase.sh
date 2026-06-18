#!/bin/bash

# ============================================
# SUPABASE SETUP SCRIPT
# ============================================
# This script configures the project to use Supabase as the database
# Run with: ./scripts/setup-supabase.sh
# Or via Makefile: make setup-supabase
# ============================================

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Configuration
BACKEND_PATH="./backend"
ENV_FILE="$BACKEND_PATH/.env"
ENV_EXAMPLE="$BACKEND_PATH/.env.example"

# Supabase project configuration
SUPABASE_PROJECT_REF="zcnlwipvjmwbofawoqit"
SUPABASE_URL="https://${SUPABASE_PROJECT_REF}.supabase.co"
SUPABASE_ANON_KEY="sb_publishable_0QEm_w1PBuVjxHYTxdhJaQ_BBiD0b9T"

print_header() {
    echo -e "\n${BLUE}============================================${NC}"
    echo -e "${BLUE}  $1${NC}"
    echo -e "${BLUE}============================================${NC}\n"
}

print_ok() {
    echo -e "${GREEN}✅ $1${NC}"
}

print_warn() {
    echo -e "${YELLOW}⚠️  $1${NC}"
}

print_error() {
    echo -e "${RED}❌ $1${NC}"
}

print_info() {
    echo -e "${BLUE}ℹ️  $1${NC}"
}

# Function to check if .env exists
check_env_file() {
    if [ ! -f "$ENV_FILE" ]; then
        print_warn ".env file not found. Creating from template..."
        if [ -f "$ENV_EXAMPLE" ]; then
            cp "$ENV_EXAMPLE" "$ENV_FILE"
            print_ok "Created .env from .env.example"
        else
            print_error ".env.example not found!"
            exit 1
        fi
    fi
}

# Function to update or add a variable in .env
update_env_var() {
    local key=$1
    local value=$2
    local file=$3
    
    if grep -q "^${key}=" "$file" 2>/dev/null; then
        # Update existing variable
        sed -i "s|^${key}=.*|${key}=\"${value}\"|" "$file"
    elif grep -q "^# ${key}=" "$file" 2>/dev/null; then
        # Uncomment and update
        sed -i "s|^# ${key}=.*|${key}=\"${value}\"|" "$file"
    else
        # Add new variable
        echo "${key}=\"${value}\"" >> "$file"
    fi
}

# Function to configure Supabase
configure_supabase() {
    print_header "SUPABASE CONFIGURATION"
    
    echo -e "This script will configure your project to use Supabase.\n"
    echo -e "Your Supabase project: ${GREEN}${SUPABASE_URL}${NC}"
    echo -e "Dashboard: ${BLUE}https://supabase.com/dashboard/project/${SUPABASE_PROJECT_REF}${NC}\n"
    
    # Check if running in interactive mode
    if [ -t 0 ]; then
        # Interactive mode - ask for password
        echo -e "${YELLOW}Please enter your Supabase database password:${NC}"
        echo -e "(Find it at: https://supabase.com/dashboard/project/${SUPABASE_PROJECT_REF}/settings/database)"
        read -s -p "Password: " DB_PASSWORD
        echo ""
    else
        # Non-interactive mode - check for environment variable
        if [ -z "$SUPABASE_DB_PASSWORD" ]; then
            print_error "Running in non-interactive mode. Please set SUPABASE_DB_PASSWORD environment variable."
            exit 1
        fi
        DB_PASSWORD="$SUPABASE_DB_PASSWORD"
    fi
    
    if [ -z "$DB_PASSWORD" ]; then
        print_error "Password cannot be empty!"
        exit 1
    fi
    
    # URL encode the password (handle special characters)
    ENCODED_PASSWORD=$(python3 -c "import urllib.parse; print(urllib.parse.quote('$DB_PASSWORD', safe=''))" 2>/dev/null || echo "$DB_PASSWORD")
    
    # Construct connection URLs
    # Using Transaction pooler (port 6543) for application connections
    DATABASE_URL="postgresql://postgres.${SUPABASE_PROJECT_REF}:${ENCODED_PASSWORD}@aws-0-eu-west-3.pooler.supabase.com:6543/postgres?pgbouncer=true"
    
    # Direct connection (port 5432) for migrations
    DIRECT_URL="postgresql://postgres.${SUPABASE_PROJECT_REF}:${ENCODED_PASSWORD}@aws-0-eu-west-3.pooler.supabase.com:5432/postgres"
    
    print_info "Updating .env file..."
    
    # Update environment variables
    update_env_var "DATABASE_URL" "$DATABASE_URL" "$ENV_FILE"
    update_env_var "DIRECT_URL" "$DIRECT_URL" "$ENV_FILE"
    update_env_var "SUPABASE_URL" "$SUPABASE_URL" "$ENV_FILE"
    update_env_var "SUPABASE_ANON_KEY" "$SUPABASE_ANON_KEY" "$ENV_FILE"
    update_env_var "DB_MODE" "supabase" "$ENV_FILE"
    
    print_ok "Environment variables updated!"
}

# Function to update Prisma schema for Supabase
update_prisma_schema() {
    print_header "UPDATING PRISMA SCHEMA"
    
    local SCHEMA_FILE="$BACKEND_PATH/prisma/schema.prisma"
    
    # Check if directUrl is already configured
    if grep -q "directUrl" "$SCHEMA_FILE"; then
        print_info "Prisma schema already configured for Supabase"
    else
        # Add directUrl to datasource
        sed -i 's/datasource db {/datasource db {\n  directUrl = env("DIRECT_URL")/' "$SCHEMA_FILE"
        print_ok "Added directUrl to Prisma schema"
    fi
}

# Function to test connection
test_connection() {
    print_header "TESTING DATABASE CONNECTION"
    
    cd "$BACKEND_PATH"
    
    print_info "Testing Supabase connection..."
    
    # Run a simple Prisma command to test connection
    if npx prisma db pull --schema=prisma/schema.prisma 2>/dev/null; then
        print_ok "Successfully connected to Supabase!"
    else
        print_warn "Could not connect. Please check your credentials."
        print_info "You can test manually with: cd backend && npx prisma db pull"
    fi
    
    cd - > /dev/null
}

# Function to run migrations on Supabase
run_migrations() {
    print_header "RUNNING MIGRATIONS"
    
    cd "$BACKEND_PATH"
    
    print_info "Pushing schema to Supabase..."
    
    # Generate Prisma client first
    npx prisma generate --schema=prisma/schema.prisma
    
    # Push schema to database (for initial setup) or run migrations
    if [ -d "prisma/migrations" ] && [ "$(ls -A prisma/migrations 2>/dev/null)" ]; then
        print_info "Found existing migrations. Deploying..."
        npx prisma migrate deploy --schema=prisma/schema.prisma
    else
        print_info "No migrations found. Using db push for initial setup..."
        npx prisma db push --schema=prisma/schema.prisma
    fi
    
    print_ok "Database schema synchronized!"
    
    cd - > /dev/null
}

# Function to seed database
seed_database() {
    print_header "SEEDING DATABASE"
    
    cd "$BACKEND_PATH"
    
    read -p "Do you want to seed the database with sample data? (y/N) " -n 1 -r
    echo ""
    
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        print_info "Seeding database..."
        npm run seed
        print_ok "Database seeded successfully!"
    else
        print_info "Skipping database seeding."
    fi
    
    cd - > /dev/null
}

# Function to configure for local development
configure_local() {
    print_header "LOCAL DOCKER CONFIGURATION"
    
    # Local Docker configuration
    DATABASE_URL="postgresql://postgres:postgres@localhost:5432/vite_gourmand?schema=public"
    
    update_env_var "DATABASE_URL" "$DATABASE_URL" "$ENV_FILE"
    update_env_var "DB_MODE" "local" "$ENV_FILE"
    
    # Comment out Supabase-specific vars
    sed -i 's/^DIRECT_URL=/# DIRECT_URL=/' "$ENV_FILE" 2>/dev/null || true
    
    print_ok "Configured for local Docker development"
}

# Main menu
main_menu() {
    print_header "VITE GOURMAND - DATABASE SETUP"
    
    echo "Select your database configuration:"
    echo ""
    echo "  1) Configure Supabase (production/staging)"
    echo "  2) Configure Local Docker (development)"
    echo "  3) Test current connection"
    echo "  4) Run migrations"
    echo "  5) Seed database"
    echo "  6) Full Supabase setup (configure + migrate + seed)"
    echo "  0) Exit"
    echo ""
    read -p "Enter your choice: " choice
    
    case $choice in
        1)
            check_env_file
            configure_supabase
            update_prisma_schema
            ;;
        2)
            check_env_file
            configure_local
            ;;
        3)
            test_connection
            ;;
        4)
            run_migrations
            ;;
        5)
            seed_database
            ;;
        6)
            check_env_file
            configure_supabase
            update_prisma_schema
            run_migrations
            seed_database
            print_ok "Full Supabase setup complete!"
            ;;
        0)
            print_info "Goodbye!"
            exit 0
            ;;
        *)
            print_error "Invalid option"
            exit 1
            ;;
    esac
}

# Handle command line arguments
case "${1:-}" in
    --supabase|-s)
        check_env_file
        configure_supabase
        update_prisma_schema
        ;;
    --local|-l)
        check_env_file
        configure_local
        ;;
    --migrate|-m)
        run_migrations
        ;;
    --seed)
        seed_database
        ;;
    --test|-t)
        test_connection
        ;;
    --full|-f)
        check_env_file
        configure_supabase
        update_prisma_schema
        run_migrations
        seed_database
        print_ok "Full Supabase setup complete!"
        ;;
    --help|-h)
        echo "Usage: $0 [OPTION]"
        echo ""
        echo "Options:"
        echo "  --supabase, -s    Configure for Supabase"
        echo "  --local, -l       Configure for local Docker"
        echo "  --migrate, -m     Run database migrations"
        echo "  --seed            Seed the database"
        echo "  --test, -t        Test database connection"
        echo "  --full, -f        Full Supabase setup (configure + migrate + seed)"
        echo "  --help, -h        Show this help message"
        echo ""
        echo "Without arguments, shows interactive menu."
        ;;
    "")
        main_menu
        ;;
    *)
        print_error "Unknown option: $1"
        echo "Use --help for usage information"
        exit 1
        ;;
esac

print_info "Done!"
