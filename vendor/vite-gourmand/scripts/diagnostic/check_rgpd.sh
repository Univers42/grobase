#!/bin/bash
# ==========================================
# RGPD Compliance Check
# ==========================================
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$SCRIPT_DIR/lib/common.sh"

function check_rgpd() {
    log_section "RGPD COMPLIANCE CHECK"
    print_header "🔐 RGPD COMPLIANCE CHECK"
    reset_counters
    
    # 1. Password Security
    echo ""
    echo "1️⃣  Password Security"
    log_subsection "1. Password Security (bcrypt)"
    
    if check_package_installed "bcrypt"; then
        count_pass
        
        if [[ "$VERBOSE" == "true" ]]; then
            log_detail "Checking bcrypt usage in codebase..."
            local bcrypt_usage
            bcrypt_usage=$(grep -r "bcrypt" "$BACKEND_PATH/src" --include="*.ts" 2>/dev/null | head -10)
            if [[ -n "$bcrypt_usage" ]]; then
                log_pass "bcrypt is actively used:"
                while IFS= read -r line; do
                    log_code "$line"
                done <<< "$bcrypt_usage"
            fi
            
            # Verify in database
            log_detail ""
            log_detail "Verifying password hashing in database..."
            local pwd_sample
            pwd_sample=$(docker exec -e PGPASSWORD=postgres "$POSTGRES_CONTAINER" psql -U postgres -d vite_gourmand -tAc "SELECT password FROM \"User\" LIMIT 1;" 2>&1)
            if [[ "$pwd_sample" == \$2* ]]; then
                log_pass "DATABASE VERIFICATION: Passwords ARE bcrypt hashed!"
                log_detail "Sample hash prefix: ${pwd_sample:0:30}..."
                log_detail "Hash format: \$2[aby]\$[cost]\$[22 char salt][31 char hash]"
                print_ok "Passwords verified as bcrypt hashed in DB"
                count_pass
            elif [[ -z "$pwd_sample" ]]; then
                log_warn "No users in database - cannot verify hashing"
                print_warn "No users in database - run 'make seed_db_playground'"
                count_warn
            else
                log_fail "WARNING: Passwords may NOT be hashed!"
                print_error "Passwords may not be properly hashed!"
                count_fail
            fi
        fi
    else
        print_error "bcrypt not installed - passwords may not be hashed!"
        count_fail
    fi

    # 2. Audit Logging
    echo ""
    echo "2️⃣  Audit Logging (Data Traceability)"
    log_subsection "2. Audit Logging"
    
    if [[ -f "$BACKEND_PATH/src/mongo/schemas.ts" ]] && grep -q "AuditLog\|audit" "$BACKEND_PATH/src/mongo/schemas.ts" 2>/dev/null; then
        print_ok "AuditLog schema exists"
        log_pass "AuditLog schema exists"
        count_pass
        
        if [[ "$VERBOSE" == "true" ]]; then
            log_detail "Checking audit logs in MongoDB..."
            local audit_count
            audit_count=$(docker exec "$MONGO_CONTAINER" mongosh -u root -p example --authenticationDatabase admin vite_gourmand --eval "db.audit_logs.countDocuments()" --quiet 2>&1)
            log_detail "Total audit log entries: $audit_count"
            
            if [[ "$audit_count" != "0" ]] && [[ "$audit_count" =~ ^[0-9]+$ ]]; then
                log_pass "Audit logs are being recorded"
            else
                log_warn "No audit logs yet"
            fi
        fi
    else
        print_warn "AuditLog schema missing"
        log_warn "AuditLog schema missing - consider adding for RGPD"
        count_warn
    fi
    
    if grep -q "LoggingInterceptor" "$BACKEND_PATH/src/app.module.ts" 2>/dev/null; then
        print_ok "LoggingInterceptor registered"
        log_pass "LoggingInterceptor registered"
        count_pass
    else
        print_warn "LoggingInterceptor not registered"
        log_warn "LoggingInterceptor not registered"
        count_warn
    fi

    # 3. Data Validation
    echo ""
    echo "3️⃣  Data Validation (Input Sanitization)"
    log_subsection "3. Data Validation"
    
    if grep -q "ValidationPipe\|CustomValidationPipe" "$BACKEND_PATH/src/app.module.ts" 2>/dev/null; then
        print_ok "Validation pipe registered"
        log_pass "Validation pipe registered"
        count_pass
        
        if [[ "$VERBOSE" == "true" ]]; then
            log_detail "Checking DTO validation decorators..."
            local dto_decorators
            dto_decorators=$(grep -r "@Is\|@Min\|@Max\|@Length\|@Matches" "$BACKEND_PATH/src" --include="*.dto.ts" 2>/dev/null | head -15)
            if [[ -n "$dto_decorators" ]]; then
                log_pass "Validation decorators found:"
                while IFS= read -r line; do
                    log_code "$line"
                done <<< "$dto_decorators"
            fi
        fi
    else
        print_error "Validation pipe not registered"
        log_fail "Validation pipe not registered"
        count_fail
    fi

    # 4. Error Handling (No Data Leakage)
    echo ""
    echo "4️⃣  Error Handling (No Data Leakage)"
    log_subsection "4. Error Handling"
    
    if [[ -f "$BACKEND_PATH/src/common/filters/all-exceptions.filter.ts" ]]; then
        if grep -q "INTERNAL_ERROR\|Internal server error" "$BACKEND_PATH/src/common/filters/all-exceptions.filter.ts" 2>/dev/null; then
            print_ok "Internal errors are masked from clients"
            log_pass "Internal errors are masked"
            count_pass
        else
            print_warn "Check error masking implementation"
            log_warn "Check error masking"
            count_warn
        fi
    else
        print_error "AllExceptionsFilter missing"
        log_fail "AllExceptionsFilter missing"
        count_fail
    fi

    # 5. Data Encryption at Rest
    echo ""
    echo "5️⃣  Data Encryption"
    log_subsection "5. Data Encryption"
    
    # Check for SSL/TLS in database connection
    if grep -q "sslmode=\|ssl=true" "$BACKEND_PATH/.env" 2>/dev/null; then
        print_ok "Database SSL enabled"
        log_pass "Database SSL enabled"
        count_pass
    else
        print_warn "Database SSL not explicitly configured (may use local connection)"
        log_warn "Database SSL not configured"
        count_warn
    fi
    
    # Check JWT signing
    if grep -q "@nestjs/jwt" "$BACKEND_PATH/package.json" 2>/dev/null; then
        print_ok "JWT library installed for secure tokens"
        log_pass "JWT library installed"
        count_pass
    else
        print_error "JWT library not installed"
        log_fail "JWT library not installed"
        count_fail
    fi

    # 6. Data Minimization
    echo ""
    echo "6️⃣  Data Minimization"
    log_subsection "6. Data Minimization"
    
    # Check for excludeExtraneousValues in transform
    if grep -q "excludeExtraneousValues" "$BACKEND_PATH/src" -r --include="*.ts" 2>/dev/null; then
        print_ok "Data exposure control (excludeExtraneousValues)"
        log_pass "excludeExtraneousValues found"
        count_pass
    else
        print_warn "Consider using excludeExtraneousValues for DTOs"
        log_warn "excludeExtraneousValues not found"
        count_warn
    fi
    
    # Check password exclusion in responses
    if grep -r "Exclude\|@Exclude\|password.*exclude" "$BACKEND_PATH/src" --include="*.ts" 2>/dev/null | grep -q .; then
        print_ok "Sensitive fields excluded from responses"
        log_pass "Sensitive field exclusion found"
        count_pass
    else
        print_warn "Ensure password is excluded from API responses"
        log_warn "Check password exclusion in responses"
        count_warn
    fi

    # 7. Right to be Forgotten
    echo ""
    echo "7️⃣  Right to be Forgotten"
    log_subsection "7. Data Deletion Capability"
    
    # Check for CASCADE deletions in Prisma
    if grep -q "onDelete:" "$BACKEND_PATH/prisma/schema.prisma" 2>/dev/null; then
        print_ok "Cascade deletion configured in schema"
        log_pass "Cascade deletions configured"
        count_pass
    else
        print_warn "Consider adding cascade deletions for RTBF compliance"
        log_warn "No cascade deletions found"
        count_warn
    fi

    # 8. Consent Management
    echo ""
    echo "8️⃣  Consent Management"
    log_subsection "8. Consent Tracking"
    
    # Check in TypeScript code or Prisma schema
    if grep -r "consent\|gdpr\|privacy" "$BACKEND_PATH/src" "$BACKEND_PATH/prisma/schema.prisma" --include="*.ts" -i 2>/dev/null | grep -q .; then
        print_ok "Consent-related code found"
        log_pass "Consent management code found"
        count_pass
    elif grep -qi "consent\|gdpr" "$BACKEND_PATH/prisma/schema.prisma" 2>/dev/null; then
        print_ok "GDPR consent fields in database schema"
        log_pass "Consent fields in Prisma schema"
        count_pass
    else
        print_warn "Consider implementing consent tracking"
        log_warn "No consent tracking found"
        count_warn
    fi

    print_summary
    log_end_section
    print_verbose
}

# Run if executed directly
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    check_rgpd
fi
