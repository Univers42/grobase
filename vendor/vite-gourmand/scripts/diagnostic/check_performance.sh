#!/bin/bash
# ==========================================
# Performance Check
# ==========================================
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$SCRIPT_DIR/lib/common.sh"

function check_performance() {
    log_section "PERFORMANCE CHECK"
    print_header "⚡ PERFORMANCE CHECK"
    reset_counters

    # 1. Database Connection Pooling
    echo ""
    echo "1️⃣  Database Connection Pooling"
    log_subsection "1. Connection Pool Configuration"
    
    # Check Prisma connection pool
    if grep -q "connection_limit\|pool" "$BACKEND_PATH/.env" 2>/dev/null; then
        print_ok "Connection pool configured in .env"
        log_pass "Connection pool configured"
        count_pass
    else
        print_warn "Consider configuring connection pool"
        log_warn "Connection pool not explicitly configured"
        count_warn
    fi
    
    # Check for connection reuse (PrismaService singleton)
    if grep -q "@Injectable\|OnModuleInit" "$BACKEND_PATH/src/prisma/prisma.service.ts" 2>/dev/null; then
        print_ok "PrismaService is injectable singleton"
        log_pass "PrismaService singleton pattern"
        count_pass
    fi

    # 2. Caching
    echo ""
    echo "2️⃣  Caching Strategy"
    log_subsection "2. Caching"
    
    if grep -q "@nestjs/cache-manager\|cache-manager\|redis" "$BACKEND_PATH/package.json" 2>/dev/null; then
        print_ok "Cache manager installed"
        log_pass "Cache manager installed"
        count_pass
        
        if grep -r "CacheModule\|@UseInterceptors.*Cache" "$BACKEND_PATH/src" --include="*.ts" 2>/dev/null | grep -q .; then
            print_ok "Caching configured in modules"
            log_pass "Caching configured"
            count_pass
        fi
    else
        print_warn "Consider adding caching for performance"
        log_warn "No cache manager installed"
        count_warn
    fi

    # 3. Query Optimization
    echo ""
    echo "3️⃣  Query Optimization"
    log_subsection "3. Database Query Patterns"
    
    # Check for includes (eager loading)
    if grep -r "include:" "$BACKEND_PATH/src" --include="*.ts" 2>/dev/null | grep -q .; then
        print_ok "Prisma includes used (reduces N+1 queries)"
        log_pass "Eager loading with includes"
        count_pass
    else
        print_warn "Consider using includes to avoid N+1 queries"
        log_warn "No includes found"
        count_warn
    fi
    
    # Check for select (field limiting)
    if grep -r "select:" "$BACKEND_PATH/src" --include="*.ts" 2>/dev/null | grep -q .; then
        print_ok "Prisma select used (fetches only needed fields)"
        log_pass "Field selection optimized"
        count_pass
    else
        print_warn "Consider using select to limit fetched fields"
        log_warn "No select found"
        count_warn
    fi
    
    # Check for pagination
    if grep -r "skip:\|take:\|findMany.*take\|limit" "$BACKEND_PATH/src" --include="*.ts" 2>/dev/null | grep -q .; then
        print_ok "Pagination implemented"
        log_pass "Pagination found"
        count_pass
    else
        print_warn "Consider implementing pagination for large datasets"
        log_warn "No pagination found"
        count_warn
    fi

    # 4. Database Indexes
    echo ""
    echo "4️⃣  Database Indexes"
    log_subsection "4. Index Optimization"
    
    if grep -q "@index\|@@index\|@@unique" "$BACKEND_PATH/prisma/schema.prisma" 2>/dev/null; then
        print_ok "Indexes defined in Prisma schema"
        log_pass "Database indexes configured"
        count_pass
        
        if [[ "$VERBOSE" == "true" ]]; then
            log_detail "Indexes in schema:"
            grep -n "@index\|@@index\|@@unique" "$BACKEND_PATH/prisma/schema.prisma" | while IFS= read -r line; do
                log_code "$line"
            done
        fi
    else
        print_warn "Consider adding indexes for frequently queried fields"
        log_warn "No custom indexes in schema"
        count_warn
    fi
    
    # Check PostgreSQL actual indexes
    if [[ "$VERBOSE" == "true" ]]; then
        log_detail "Checking PostgreSQL indexes..."
        local pg_indexes
        pg_indexes=$(docker exec -e PGPASSWORD=postgres "$POSTGRES_CONTAINER" psql -U postgres -d vite_gourmand -c "SELECT tablename, indexname FROM pg_indexes WHERE schemaname = 'public' ORDER BY tablename;" 2>&1)
        log_detail "PostgreSQL indexes:"
        while IFS= read -r line; do
            log_code "$line"
        done <<< "$pg_indexes"
    fi

    # 5. Response Compression
    echo ""
    echo "5️⃣  Response Compression"
    log_subsection "5. Compression"
    
    if grep -q "compression" "$BACKEND_PATH/package.json" 2>/dev/null; then
        print_ok "Compression middleware installed"
        log_pass "Compression installed"
        count_pass
    else
        print_warn "Consider adding compression for API responses"
        log_warn "No compression middleware"
        count_warn
    fi

    # 6. Lazy Loading
    echo ""
    echo "6️⃣  Module Lazy Loading"
    log_subsection "6. Lazy Loading"
    
    if grep -r "forwardRef\|LazyModuleLoader" "$BACKEND_PATH/src" --include="*.ts" 2>/dev/null | grep -q .; then
        print_ok "Lazy loading patterns found"
        log_pass "Lazy loading implemented"
        count_pass
    else
        print_info "Lazy loading optional for small apps"
        log_detail "Lazy loading not implemented (OK for small apps)"
    fi

    # 7. Memory Usage
    echo ""
    echo "7️⃣  Memory Configuration"
    log_subsection "7. Memory Management"
    
    # Check Node.js memory settings
    if grep -q "NODE_OPTIONS\|--max-old-space-size" "$BACKEND_PATH/package.json" 2>/dev/null; then
        print_ok "Node.js memory options configured"
        log_pass "Memory options set"
        count_pass
    else
        print_info "Default Node.js memory settings used"
        log_detail "Using default memory settings"
    fi
    
    # Check for memory leaks prevention
    if grep -r "OnModuleDestroy\|\$disconnect" "$BACKEND_PATH/src" --include="*.ts" 2>/dev/null | grep -q .; then
        print_ok "Cleanup hooks implemented"
        log_pass "Resource cleanup found"
        count_pass
    fi

    # 8. Docker Performance
    echo ""
    echo "8️⃣  Container Performance"
    log_subsection "8. Docker Configuration"
    
    if [[ -f "docker-compose.yml" ]]; then
        # Check for resource limits
        if grep -q "mem_limit\|cpus\|deploy:" "docker-compose.yml" 2>/dev/null; then
            print_ok "Container resource limits configured"
            log_pass "Resource limits set"
            count_pass
        else
            print_warn "Consider adding resource limits to containers"
            log_warn "No resource limits in docker-compose"
            count_warn
        fi
        
        # Check for health checks
        if grep -q "healthcheck:" "docker-compose.yml" 2>/dev/null; then
            print_ok "Health checks configured"
            log_pass "Health checks configured"
            count_pass
        fi
    fi

    # 9. API Response Time
    echo ""
    echo "9️⃣  Response Time Monitoring"
    log_subsection "9. Performance Monitoring"
    
    if grep -r "LoggingInterceptor\|performance\|timing" "$BACKEND_PATH/src" --include="*.ts" 2>/dev/null | grep -q .; then
        print_ok "Response time logging found"
        log_pass "Performance logging implemented"
        count_pass
    else
        print_warn "Consider adding response time logging"
        log_warn "No performance logging"
        count_warn
    fi

    # 10. Bundle Size (TypeScript)
    echo ""
    echo "🔟 TypeScript Build Optimization"
    log_subsection "10. Build Configuration"
    
    if [[ -f "$BACKEND_PATH/tsconfig.build.json" ]]; then
        print_ok "Separate build tsconfig exists"
        log_pass "Build config exists"
        count_pass
        
        if grep -q "\"exclude\"" "$BACKEND_PATH/tsconfig.build.json" 2>/dev/null; then
            print_ok "Test files excluded from build"
            log_pass "Test exclusion configured"
            count_pass
        fi
    fi

    print_summary
    log_end_section
    print_verbose
}

# Run if executed directly
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    check_performance
fi
