#!/bin/bash
# ==========================================
# Docker & Infrastructure Check
# ==========================================
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$SCRIPT_DIR/lib/common.sh"

function check_docker() {
    log_section "DOCKER & INFRASTRUCTURE CHECK"
    print_header "🐳 DOCKER & INFRASTRUCTURE"
    reset_counters

    # 1. Docker Service
    echo ""
    echo "1️⃣  Docker Service"
    log_subsection "1. Docker Daemon"
    
    if docker info &>/dev/null; then
        print_ok "Docker daemon is running"
        log_pass "Docker daemon running"
        count_pass
        
        if [[ "$VERBOSE" == "true" ]]; then
            local docker_version
            docker_version=$(docker --version)
            log_detail "Docker version: $docker_version"
        fi
    else
        print_error "Docker daemon not running"
        log_fail "Docker daemon not running"
        count_fail
        return 1
    fi

    # 2. Docker Compose
    echo ""
    echo "2️⃣  Docker Compose"
    log_subsection "2. Docker Compose"
    
    if docker compose version &>/dev/null || docker-compose version &>/dev/null; then
        print_ok "Docker Compose available"
        log_pass "Docker Compose available"
        count_pass
    else
        print_error "Docker Compose not available"
        log_fail "Docker Compose not found"
        count_fail
    fi
    
    if [[ -f "docker-compose.yml" ]]; then
        print_ok "docker-compose.yml exists"
        log_pass "docker-compose.yml found"
        count_pass
    fi

    # 3. Running Containers
    echo ""
    echo "3️⃣  Running Containers"
    log_subsection "3. Container Status"
    
    echo ""
    docker compose ps 2>/dev/null || docker-compose ps 2>/dev/null
    
    local container_count
    container_count=$(docker compose ps -q 2>/dev/null | wc -l)
    
    if [[ $container_count -gt 0 ]]; then
        print_ok "$container_count containers running"
        log_pass "Containers running: $container_count"
        count_pass
    else
        print_warn "No containers running"
        log_warn "No containers"
        count_warn
    fi

    # 4. PostgreSQL Container
    echo ""
    echo "4️⃣  PostgreSQL Container"
    log_subsection "4. PostgreSQL"
    
    if docker_container_running "$POSTGRES_CONTAINER"; then
        print_ok "PostgreSQL container is running"
        log_pass "PostgreSQL running"
        count_pass
        
        if docker_container_healthy "$POSTGRES_CONTAINER"; then
            print_ok "PostgreSQL is healthy"
            log_pass "PostgreSQL healthy"
            count_pass
        else
            print_warn "PostgreSQL health check status unknown"
            log_warn "PostgreSQL health unknown"
            count_warn
        fi
        
        if [[ "$VERBOSE" == "true" ]]; then
            log_detail "PostgreSQL container details:"
            local pg_info
            pg_info=$(docker inspect "$POSTGRES_CONTAINER" --format '{{.Config.Image}}')
            log_detail "Image: $pg_info"
            
            local pg_mem
            pg_mem=$(docker stats "$POSTGRES_CONTAINER" --no-stream --format "{{.MemUsage}}" 2>/dev/null)
            log_detail "Memory usage: $pg_mem"
        fi
    else
        print_error "PostgreSQL container not running"
        log_fail "PostgreSQL not running"
        count_fail
    fi

    # 5. MongoDB Container
    echo ""
    echo "5️⃣  MongoDB Container"
    log_subsection "5. MongoDB"
    
    if docker_container_running "$MONGO_CONTAINER"; then
        print_ok "MongoDB container is running"
        log_pass "MongoDB running"
        count_pass
        
        if [[ "$VERBOSE" == "true" ]]; then
            log_detail "MongoDB container details:"
            local mongo_info
            mongo_info=$(docker inspect "$MONGO_CONTAINER" --format '{{.Config.Image}}')
            log_detail "Image: $mongo_info"
        fi
    else
        print_error "MongoDB container not running"
        log_fail "MongoDB not running"
        count_fail
    fi

    # 6. Container Volumes
    echo ""
    echo "6️⃣  Persistent Volumes"
    log_subsection "6. Volumes"
    
    local volumes
    volumes=$(docker volume ls --format "{{.Name}}" 2>/dev/null | grep -E "postgres|mongo|pgdata|vite" | head -5)
    if [[ -n "$volumes" ]]; then
        print_ok "Persistent volumes found"
        log_pass "Volumes found"
        count_pass
        
        while IFS= read -r vol; do
            echo "   - $vol"
            log_code "$vol"
        done <<< "$volumes"
    else
        print_warn "No project volumes found"
        log_warn "No volumes"
        count_warn
    fi

    # 7. Container Networks
    echo ""
    echo "7️⃣  Docker Networks"
    log_subsection "7. Networks"
    
    local networks
    networks=$(docker network ls --format "{{.Name}}" 2>/dev/null | grep -E "vite|gourmand|default" | head -5)
    if [[ -n "$networks" ]]; then
        print_ok "Docker networks configured"
        log_pass "Networks found"
        count_pass
        
        if [[ "$VERBOSE" == "true" ]]; then
            while IFS= read -r net; do
                log_code "$net"
            done <<< "$networks"
        fi
    fi

    # 8. Port Bindings
    echo ""
    echo "8️⃣  Port Bindings"
    log_subsection "8. Exposed Ports"
    
    echo ""
    docker compose ps --format "table {{.Name}}\t{{.Ports}}" 2>/dev/null || \
        docker-compose ps 2>/dev/null | grep -E "[0-9]+:" 
    
    # Check for common ports
    if netstat -tuln 2>/dev/null | grep -q ":5432" || ss -tuln 2>/dev/null | grep -q ":5432"; then
        print_ok "PostgreSQL port 5432 is listening"
        log_pass "Port 5432 active"
        count_pass
    fi
    
    if netstat -tuln 2>/dev/null | grep -q ":27017" || ss -tuln 2>/dev/null | grep -q ":27017"; then
        print_ok "MongoDB port 27017 is listening"
        log_pass "Port 27017 active"
        count_pass
    fi

    # 9. Disk Space
    echo ""
    echo "9️⃣  Disk Space"
    log_subsection "9. Storage"
    
    local disk_usage
    disk_usage=$(df -h . | tail -1 | awk '{print $5}')
    local disk_percent
    disk_percent=$(echo "$disk_usage" | tr -d '%')
    
    if [[ $disk_percent -lt 80 ]]; then
        print_ok "Disk usage: $disk_usage"
        log_pass "Disk usage OK: $disk_usage"
        count_pass
    elif [[ $disk_percent -lt 90 ]]; then
        print_warn "Disk usage high: $disk_usage"
        log_warn "Disk usage high: $disk_usage"
        count_warn
    else
        print_error "Disk usage critical: $disk_usage"
        log_fail "Disk usage critical: $disk_usage"
        count_fail
    fi
    
    # Docker disk usage
    if [[ "$VERBOSE" == "true" ]]; then
        log_detail "Docker disk usage:"
        docker system df 2>/dev/null | while IFS= read -r line; do
            log_code "$line"
        done
    fi

    # 10. Container Logs
    echo ""
    echo "🔟 Recent Container Logs"
    log_subsection "10. Container Logs"
    
    print_info "Recent PostgreSQL logs:"
    docker logs "$POSTGRES_CONTAINER" 2>&1 | tail -5
    
    if [[ "$VERBOSE" == "true" ]]; then
        log_detail "PostgreSQL logs (last 20 lines):"
        docker logs "$POSTGRES_CONTAINER" 2>&1 | tail -20 | while IFS= read -r line; do
            log_code "$line"
        done
        
        log_detail ""
        log_detail "MongoDB logs (last 20 lines):"
        docker logs "$MONGO_CONTAINER" 2>&1 | tail -20 | while IFS= read -r line; do
            log_code "$line"
        done
    fi

    print_summary
    log_end_section
    print_verbose
}

# Run if executed directly
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    check_docker
fi
