#!/bin/bash
# ==========================================
# RGAA Accessibility Compliance Check
# ==========================================
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$SCRIPT_DIR/lib/common.sh"

function check_rgaa() {
    log_section "RGAA COMPLIANCE CHECK"
    print_header "♿ RGAA ACCESSIBILITY COMPLIANCE"
    reset_counters
    
    print_info "RGAA is primarily a frontend concern."
    print_info "Backend should provide consistent, accessible API responses."
    log_detail "RGAA is primarily a frontend concern. Backend provides:"
    log_detail "- Clear error messages"
    log_detail "- Consistent API response format"
    log_detail "- Proper HTTP status codes"
    echo ""

    # 1. Clear Error Messages
    echo ""
    echo "1️⃣  Clear Error Messages"
    log_subsection "1. Error Message Clarity"
    
    if check_file_exists "$BACKEND_PATH/src/common/dto/api-response.dto.ts" "ApiResponse DTO"; then
        count_pass
        if [[ "$VERBOSE" == "true" ]]; then
            log_file_content "$BACKEND_PATH/src/common/dto/api-response.dto.ts"
        fi
    else
        count_fail
    fi

    # 2. Validation Messages
    echo ""
    echo "2️⃣  Custom Validation Messages"
    log_subsection "2. Validation Message Quality"
    
    local has_messages=false
    if grep -q "message:" "$BACKEND_PATH/src/auth/dto/"*.dto.ts 2>/dev/null; then
        print_ok "Custom validation messages exist"
        log_pass "Custom validation messages exist"
        count_pass
        has_messages=true
        
        if [[ "$VERBOSE" == "true" ]]; then
            log_detail "Sample validation messages:"
            grep -r "message:" "$BACKEND_PATH/src" --include="*.dto.ts" | head -10 | while IFS= read -r line; do
                log_code "$line"
            done
        fi
    else
        print_warn "Consider adding custom validation messages"
        log_warn "No custom validation messages found"
        count_warn
    fi

    # 3. HTTP Status Codes
    echo ""
    echo "3️⃣  Proper HTTP Status Codes"
    log_subsection "3. HTTP Status Code Usage"
    
    local status_codes_found=0
    if grep -r "HttpStatus\." "$BACKEND_PATH/src" --include="*.ts" 2>/dev/null | grep -q .; then
        print_ok "HttpStatus enum used for proper status codes"
        log_pass "HttpStatus enum used"
        count_pass
        status_codes_found=1
        
        if [[ "$VERBOSE" == "true" ]]; then
            log_detail "Status codes used in codebase:"
            grep -r "HttpStatus\." "$BACKEND_PATH/src" --include="*.ts" 2>/dev/null | \
                sed 's/.*HttpStatus\.\([A-Z_]*\).*/\1/' | sort | uniq -c | while IFS= read -r line; do
                log_code "$line"
            done
        fi
    else
        print_warn "HttpStatus enum not widely used"
        log_warn "Consider using HttpStatus enum"
        count_warn
    fi

    # 4. Content-Type Headers
    echo ""
    echo "4️⃣  Content-Type Consistency"
    log_subsection "4. Content-Type Headers"
    
    # NestJS defaults to JSON, which is good
    print_ok "NestJS defaults to application/json content-type"
    log_pass "JSON content-type by default"
    count_pass

    # 5. Language Support (i18n)
    echo ""
    echo "5️⃣  Internationalization (i18n)"
    log_subsection "5. i18n Support"
    
    if grep -q "nestjs-i18n\|i18n" "$BACKEND_PATH/package.json" 2>/dev/null; then
        print_ok "i18n library installed"
        log_pass "i18n library installed"
        count_pass
    else
        print_warn "Consider adding i18n for multi-language support"
        log_warn "No i18n library found"
        count_warn
    fi

    # 6. Rate Limiting (for accessibility - prevent blocking)
    echo ""
    echo "6️⃣  Rate Limiting (Prevent Blocking Legitimate Users)"
    log_subsection "6. Rate Limiting"
    
    if grep -q "@nestjs/throttler\|throttler\|rate-limit" "$BACKEND_PATH/package.json" 2>/dev/null; then
        print_ok "Rate limiting configured"
        log_pass "Rate limiting configured"
        count_pass
    else
        print_warn "Consider adding rate limiting"
        log_warn "No rate limiting found"
        count_warn
    fi

    # 7. API Documentation
    echo ""
    echo "7️⃣  API Documentation (Swagger)"
    log_subsection "7. API Documentation"
    
    if grep -q "@nestjs/swagger" "$BACKEND_PATH/package.json" 2>/dev/null; then
        print_ok "Swagger documentation installed"
        log_pass "Swagger installed"
        count_pass
        
        if [[ "$VERBOSE" == "true" ]]; then
            # Check for API decorators
            local api_decorators
            api_decorators=$(grep -r "@Api\|@ApiTags\|@ApiOperation" "$BACKEND_PATH/src" --include="*.ts" 2>/dev/null | wc -l)
            log_detail "API documentation decorators found: $api_decorators"
        fi
    else
        print_warn "Consider adding Swagger for API documentation"
        log_warn "No Swagger documentation"
        count_warn
    fi

    # 8. Timeout Configuration
    echo ""
    echo "8️⃣  Request Timeouts"
    log_subsection "8. Timeout Configuration"
    
    if grep -r "timeout\|Timeout" "$BACKEND_PATH/src" --include="*.ts" 2>/dev/null | grep -q .; then
        print_ok "Timeout configuration found"
        log_pass "Timeout configuration found"
        count_pass
    else
        print_warn "Consider configuring request timeouts"
        log_warn "No timeout configuration found"
        count_warn
    fi

    # Frontend RGAA Checks (if frontend exists)
    echo ""
    echo "9️⃣  Frontend Accessibility (Quick Check)"
    log_subsection "9. Frontend Accessibility"
    
    if [[ -d "$FRONTEND_PATH" ]]; then
        # Check for accessibility packages
        if grep -q "axe-core\|react-aria\|@reach\|headlessui\|a11y" "$FRONTEND_PATH/package.json" 2>/dev/null; then
            print_ok "Accessibility libraries found in frontend"
            log_pass "Accessibility libraries found"
            count_pass
        else
            print_warn "Consider adding accessibility testing libraries"
            log_warn "No a11y libraries in frontend"
            count_warn
        fi
        
        # Check for ARIA usage
        if grep -r "aria-\|role=" "$FRONTEND_PATH/src" --include="*.tsx" --include="*.jsx" 2>/dev/null | grep -q .; then
            print_ok "ARIA attributes found in frontend components"
            log_pass "ARIA attributes used"
            count_pass
        else
            print_warn "Consider adding ARIA attributes to components"
            log_warn "No ARIA attributes found"
            count_warn
        fi
        
        # Check for alt text
        if grep -r "alt=" "$FRONTEND_PATH/src" --include="*.tsx" --include="*.jsx" 2>/dev/null | grep -q .; then
            print_ok "Alt text attributes found for images"
            log_pass "Alt text used"
            count_pass
        else
            print_warn "Ensure all images have alt text"
            log_warn "Check image alt text"
            count_warn
        fi
    else
        print_info "Frontend not found - skipping frontend checks"
        log_detail "Frontend not found at $FRONTEND_PATH"
    fi

    print_summary
    log_end_section
    print_verbose
}

# Run if executed directly
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    check_rgaa
fi
