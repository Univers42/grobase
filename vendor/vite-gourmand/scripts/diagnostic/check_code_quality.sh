#!/bin/bash
# ==========================================
# Code Quality Check
# ==========================================
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$SCRIPT_DIR/lib/common.sh"

function check_code_quality() {
    log_section "CODE QUALITY CHECK"
    print_header "📝 CODE QUALITY CHECK"
    reset_counters

    # 1. ESLint Configuration
    echo ""
    echo "1️⃣  ESLint Configuration"
    log_subsection "1. Linting"
    if [[ -f "$BACKEND_PATH/eslint.config.mjs" ]] || [[ -f "$BACKEND_PATH/.eslintrc.js" ]] || [[ -f "$BACKEND_PATH/.eslintrc.json" ]]; then
        print_ok "ESLint configured"
        log_pass "ESLint configuration found"
        count_pass
        if grep -q "\"lint\"" "$BACKEND_PATH/package.json" 2>/dev/null; then
            print_ok "Lint script in package.json"
            log_pass "Lint script exists"
            count_pass
        fi
    else
        print_error "ESLint not configured"
        log_fail "No ESLint configuration"
        count_fail
    fi

    # 2. Prettier Configuration
    echo ""
    echo "2️⃣  Prettier Configuration"
    log_subsection "2. Code Formatting"
    
    if [[ -f "$BACKEND_PATH/.prettierrc" ]] || [[ -f "$BACKEND_PATH/.prettierrc.json" ]] || grep -q "prettier" "$BACKEND_PATH/package.json" 2>/dev/null; then
        print_ok "Prettier configured"
        log_pass "Prettier configuration found"
        count_pass
    else
        print_warn "Consider adding Prettier for code formatting"
        log_warn "No Prettier configuration"
        count_warn
    fi

    # 3. TypeScript Strict Mode
    echo ""
    echo "3️⃣  TypeScript Configuration"
    log_subsection "3. TypeScript Strictness"
    
    if grep -q "\"strict\": true" "$BACKEND_PATH/tsconfig.json" 2>/dev/null; then
        print_ok "TypeScript strict mode enabled"
        log_pass "Strict mode enabled"
        count_pass
    else
        print_warn "Consider enabling TypeScript strict mode"
        log_warn "Strict mode not enabled"
        count_warn
    fi
    
    if grep -q "\"noImplicitAny\": true" "$BACKEND_PATH/tsconfig.json" 2>/dev/null; then
        print_ok "noImplicitAny enabled"
        log_pass "noImplicitAny enabled"
        count_pass
    fi
    
    if grep -q "\"strictNullChecks\": true" "$BACKEND_PATH/tsconfig.json" 2>/dev/null; then
        print_ok "strictNullChecks enabled"
        log_pass "strictNullChecks enabled"
        count_pass
    fi

    # 4. Test Coverage
    echo ""
    echo "4️⃣  Test Coverage"
    log_subsection "4. Testing"
    
    local test_files
    test_files=$(find "$BACKEND_PATH/src" -name "*.spec.ts" 2>/dev/null | wc -l)
    echo "   Found $test_files test files"
    log_detail "Test files found: $test_files"
    
    if [[ $test_files -gt 0 ]]; then
        print_ok "Unit tests exist ($test_files files)"
        log_pass "Unit tests found"
        count_pass
    else
        print_warn "No unit tests found"
        log_warn "No unit tests"
        count_warn
    fi
    
    # Check for e2e tests
    local e2e_tests
    e2e_tests=$(find "$BACKEND_PATH/test" -name "*.e2e-spec.ts" 2>/dev/null | wc -l)
    if [[ $e2e_tests -gt 0 ]]; then
        print_ok "E2E tests exist ($e2e_tests files)"
        log_pass "E2E tests found"
        count_pass
    else
        print_warn "No E2E tests found"
        log_warn "No E2E tests"
        count_warn
    fi
    
    # Check for coverage configuration
    if grep -q "coverage\|collectCoverage" "$BACKEND_PATH/package.json" 2>/dev/null; then
        print_ok "Test coverage configured"
        log_pass "Coverage configuration found"
        count_pass
    fi

    # 5. Code Documentation
    echo ""
    echo "5️⃣  Code Documentation"
    log_subsection "5. Documentation"
    
    # Check for JSDoc comments
    local jsdoc_count
    jsdoc_count=$(grep -r "/\*\*" "$BACKEND_PATH/src" --include="*.ts" 2>/dev/null | wc -l)
    if [[ $jsdoc_count -gt 10 ]]; then
        print_ok "JSDoc comments found ($jsdoc_count occurrences)"
        log_pass "JSDoc documentation found"
        count_pass
    else
        print_warn "Consider adding more JSDoc comments"
        log_warn "Limited JSDoc documentation"
        count_warn
    fi
    
    # Check README
    if [[ -f "$BACKEND_PATH/README.md" ]]; then
        print_ok "README.md exists"
        log_pass "README exists"
        count_pass
    fi

    # 6. Error Handling Patterns
    echo ""
    echo "6️⃣  Error Handling Patterns"
    log_subsection "6. Error Handling"
    
    # Check for try-catch blocks
    local try_catch_count
    try_catch_count=$(grep -r "try {" "$BACKEND_PATH/src" --include="*.ts" 2>/dev/null | wc -l)
    if [[ $try_catch_count -gt 5 ]]; then
        print_ok "Error handling with try-catch ($try_catch_count occurrences)"
        log_pass "Try-catch blocks found"
        count_pass
    fi
    
    # Check for custom exceptions
    if find "$BACKEND_PATH/src" -name "*exception*.ts" 2>/dev/null | grep -q .; then
        print_ok "Custom exceptions defined"
        log_pass "Custom exceptions found"
        count_pass
    fi

    # 7. Dependency Injection Patterns
    echo ""
    echo "7️⃣  Dependency Injection"
    log_subsection "7. DI Patterns"
    
    # Check for @Injectable decorators
    local injectable_count
    injectable_count=$(grep -r "@Injectable" "$BACKEND_PATH/src" --include="*.ts" 2>/dev/null | wc -l)
    if [[ $injectable_count -gt 5 ]]; then
        print_ok "Proper DI with @Injectable ($injectable_count services)"
        log_pass "DI pattern followed"
        count_pass
    fi
    
    # Check for interface-based programming
    if find "$BACKEND_PATH/src" -name "*.interface.ts" 2>/dev/null | grep -q .; then
        print_ok "Interface files found (good abstraction)"
        log_pass "Interfaces used"
        count_pass
    fi

    # 8. Code Organization
    echo ""
    echo "8️⃣  Code Organization"
    log_subsection "8. Project Structure"
    
    # Check for modular structure
    local module_count
    module_count=$(find "$BACKEND_PATH/src" -name "*.module.ts" 2>/dev/null | wc -l)
    print_info "Found $module_count modules"
    log_detail "Module count: $module_count"
    
    if [[ $module_count -gt 3 ]]; then
        print_ok "Good modular structure ($module_count modules)"
        log_pass "Modular structure"
        count_pass
    fi
    
    # Check for barrel exports
    if find "$BACKEND_PATH/src" -name "index.ts" 2>/dev/null | grep -q .; then
        print_ok "Barrel exports (index.ts) found"
        log_pass "Barrel exports used"
        count_pass
    fi

    # 9. Console.log Usage
    echo ""
    echo "9️⃣  Debug Code"
    log_subsection "9. Debug Statements"
    
    local console_logs
    console_logs=$(grep -r "console.log" "$BACKEND_PATH/src" --include="*.ts" 2>/dev/null | grep -v "\.spec\." | wc -l)
    if [[ $console_logs -gt 5 ]]; then
        print_warn "Found $console_logs console.log statements (consider using Logger)"
        log_warn "Console.log statements found: $console_logs"
        count_warn
    else
        print_ok "Limited console.log usage"
        log_pass "Proper logging"
        count_pass
    fi
    
    # Check for debugger statements
    if grep -r "debugger" "$BACKEND_PATH/src" --include="*.ts" 2>/dev/null | grep -q .; then
        print_error "Debugger statements found - remove before production!"
        log_fail "Debugger statements in code"
        count_fail
    else
        print_ok "No debugger statements"
        log_pass "No debugger statements"
        count_pass
    fi

    # 10. TODO/FIXME Comments
    echo ""
    echo "🔟 TODO/FIXME Tracking"
    log_subsection "10. Technical Debt"
    
    local todo_count
    todo_count=$(grep -r "TODO\|FIXME\|XXX\|HACK" "$BACKEND_PATH/src" --include="*.ts" 2>/dev/null | wc -l)
    if [[ $todo_count -gt 0 ]]; then
        print_warn "Found $todo_count TODO/FIXME comments"
        log_warn "Technical debt markers: $todo_count"
        count_warn
        
        if [[ "$VERBOSE" == "true" ]]; then
            log_detail "TODO/FIXME locations:"
            grep -rn "TODO\|FIXME\|XXX\|HACK" "$BACKEND_PATH/src" --include="*.ts" | head -10 | while IFS= read -r line; do
                log_code "$line"
            done
        fi
    else
        print_ok "No TODO/FIXME comments"
        log_pass "No technical debt markers"
        count_pass
    fi

    print_summary
    log_end_section
    print_verbose
}

# Run if executed directly
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    check_code_quality
fi
