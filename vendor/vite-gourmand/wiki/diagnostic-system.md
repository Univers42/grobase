# Diagnostic System Documentation

## Overview

The Vite Gourmand project includes a comprehensive diagnostic system that checks the health, security, performance, and compliance of the application. This document explains how the system works and how to use it.

## Quick Start

```bash
# Run all diagnostics
./scripts/diagnostic.sh all

# Run specific check
./scripts/diagnostic.sh routines

# Run with verbose logging
./scripts/diagnostic.sh --v all

# Interactive mode
./scripts/diagnostic.sh
```

## Architecture

```
scripts/
├── diagnostic.sh          # Main orchestrator (~220 lines)
├── lib/
│   └── common.sh          # Shared utilities, colors, logging
├── check_load_db.sh       # PostgreSQL checks
├── check_mongo.sh         # MongoDB checks
├── check_routines.sh      # Backend routines verification
├── check_rgpd.sh          # RGPD/GDPR compliance
├── check_rgaa.sh          # RGAA accessibility
├── check_security.sh      # Security configuration
├── check_performance.sh   # Performance optimizations
├── check_code_quality.sh  # Code quality/linting
├── check_docker.sh        # Docker infrastructure
└── check_tests.sh         # Backend unit tests
```

## Available Commands

| Command | Description |
|---------|-------------|
| `load_db` | Check PostgreSQL status, tables, and data |
| `mongo` | Check MongoDB status and collections |
| `routines` | Check backend routines (guards, filters, pipes) |
| `rgpd` | Check RGPD/GDPR compliance |
| `rgaa` | Check RGAA accessibility compliance |
| `security` | Check security configuration |
| `performance` | Check performance optimizations |
| `quality` | Check code quality (lint, tests, docs) |
| `docker` | Check Docker containers and infrastructure |
| `tests` | Run backend unit tests |
| `all` | Run all checks (except tests) |
| `full` | Run all checks including tests |

## How Each Check Works

### 1. Docker Check (`check_docker.sh`)

Verifies Docker infrastructure:
- Docker daemon status
- Docker Compose availability
- Running containers (PostgreSQL, MongoDB)
- Container health checks
- Port bindings (5432, 27017)
- Disk space usage

### 2. PostgreSQL Check (`check_load_db.sh`)

Validates database state:
- Container running and healthy
- Database exists
- All tables created (13 tables)
- Data seeded correctly

### 3. MongoDB Check (`check_mongo.sh`)

Validates analytics database:
- Container running
- Connection successful
- Collections exist (6 collections)
- Audit logs configured

### 4. Routines Check (`check_routines.sh`)

Verifies NestJS backend routines:
- **Authentication**: AuthModule, AuthService, AuthController, JwtStrategy
- **Guards**: JwtAuthGuard, RolesGuard
- **Validation**: CustomValidationPipe, class-validator, class-transformer
- **Error Handling**: HttpExceptionFilter, AllExceptionsFilter
- **Interceptors**: LoggingInterceptor, TransformInterceptor
- **Decorators**: @Public(), @Roles(), @CurrentUser()
- **Environment**: .env, DATABASE_URL, JWT_SECRET, MONGODB_URI
- **Database**: PrismaModule, PrismaService, schema.prisma
- **API Response**: ApiResponse DTO, Constants
- **Global Registration**: APP_GUARD, APP_FILTER, APP_INTERCEPTOR, APP_PIPE

### 5. RGPD Compliance (`check_rgpd.sh`)

Checks GDPR compliance:
- Password hashing (bcrypt)
- Audit logging
- Data validation
- Error masking (no data leakage)
- Database SSL configuration
- Data minimization (excludeExtraneousValues)
- Cascade deletions (Right to be Forgotten)
- Consent tracking

### 6. RGAA Accessibility (`check_rgaa.sh`)

Checks accessibility compliance:
- Clear error messages
- Custom validation messages
- Proper HTTP status codes
- Content-Type consistency
- i18n support
- Rate limiting
- Swagger documentation
- Request timeouts
- Frontend ARIA attributes

### 7. Security Check (`check_security.sh`)

Validates security configuration:
- Helmet.js (security headers)
- CORS configuration
- Rate limiting (Throttler)
- SQL injection protection (Prisma ORM)
- XSS protection
- Sensitive data in logs
- Environment variables security
- HTTPS/TLS readiness
- Cookie security flags
- JWT token security

### 8. Performance Check (`check_performance.sh`)

Analyzes performance optimizations:
- Database connection pooling
- Caching strategy (CacheModule)
- Query optimization (includes, select, pagination)
- Database indexes
- Response compression
- Module lazy loading
- Memory configuration
- Container resource limits
- Response time monitoring
- TypeScript build optimization

### 9. Code Quality (`check_code_quality.sh`)

Evaluates code quality:
- ESLint configuration
- Prettier configuration
- TypeScript strict mode
- Test coverage
- Code documentation (JSDoc)
- Error handling patterns
- Dependency injection
- Code organization
- Debug code detection
- TODO/FIXME tracking

## Output Format

Each check produces output in this format:

```
🔍 CHECK NAME
==========================================

1️⃣  Category Name
✅ Check passed
❌ Check failed
⚠️  Warning
ℹ️  Information

==========================================
📊 Summary: X passed, Y failed, Z warnings
==========================================
```

## Verbose Mode

Enable verbose mode for detailed logging:

```bash
./scripts/diagnostic.sh --v all
```

Logs are saved to: `./data/logs/diagnostic.txt`

## Common Library (`lib/common.sh`)

Shared functions available to all check scripts:

```bash
# Colors
$RED, $GREEN, $YELLOW, $BLUE, $NC

# Printing
print_ok "message"      # ✅ Green checkmark
print_error "message"   # ❌ Red X
print_warn "message"    # ⚠️  Yellow warning
print_info "message"    # ℹ️  Blue info
print_header "title"    # Section header

# Counters
reset_counters          # Reset pass/fail/warn counters
count_pass              # Increment pass counter
count_fail              # Increment fail counter
count_warn              # Increment warn counter
print_summary           # Print summary line

# File checks
check_file_exists "/path/to/file" "Description"
check_package_installed "package-name"
check_grep_in_file "pattern" "/path/to/file" "success msg" "fail msg"

# Docker
docker_container_running "container-name"
docker_container_healthy "container-name"

# Logging (verbose mode)
log_section "Section Name"
log_subsection "Subsection"
log_pass "message"
log_fail "message"
log_warn "message"
log_detail "message"
log_code "code snippet"
```

## Exit Codes

| Code | Meaning |
|------|---------|
| 0 | All checks passed |
| 1 | One or more checks failed |

## Extending the System

### Adding a New Check

1. Create `scripts/check_yourcheck.sh`:

```bash
#!/bin/bash
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/common.sh"

function check_yourcheck() {
    log_section "YOUR CHECK"
    print_header "🔍 YOUR CHECK"
    reset_counters

    # Your checks here
    echo ""
    echo "1️⃣  First Category"
    if [[ -f "some/file" ]]; then
        print_ok "File exists"
        count_pass
    else
        print_error "File missing"
        count_fail
    fi

    print_summary
    log_end_section
    print_verbose
}

# Run if executed directly
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    check_yourcheck
fi
```

2. Make it executable:
```bash
chmod +x scripts/check_yourcheck.sh
```

3. Add to `diagnostic.sh` dispatcher:
```bash
yourcheck)
    source "$SCRIPTS_DIR/check_yourcheck.sh"
    check_yourcheck
    ;;
```

4. Add to help text in `diagnostic.sh`

## Troubleshooting

### "Permission denied"
```bash
chmod +x scripts/*.sh
```

### "command not found: docker"
Ensure Docker is installed and in PATH.

### Counters showing wrong numbers
Fixed in `lib/common.sh` - arithmetic expressions now use `|| true` to prevent exit code issues.

### False positives in generated files
Security and other checks exclude `generated/` directories.
