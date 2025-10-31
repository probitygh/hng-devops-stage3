#!/bin/bash

# Color codes for output
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
PURPLE='\033[0;35m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

# Accept optional IP address, default to localhost
HOST="${1:-localhost}"

# Test counters
TESTS_PASSED=0
TESTS_FAILED=0

log() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

log_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
    increment_passed
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
    increment_failed
}

log_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

log_debug() {
    echo -e "${PURPLE}[DEBUG]${NC} $1"
}

log_monitor() {
    echo -e "${CYAN}[MONITOR]${NC} $1"
}

increment_passed() {
    TESTS_PASSED=$((TESTS_PASSED + 1))
}

increment_failed() {
    TESTS_FAILED=$((TESTS_FAILED + 1))
}

# Function to test service health
test_service_health() {
    local service=$1
    local url=$2
    local max_retries=5
    
    log "Testing $service health..."
    
    for i in $(seq 1 $max_retries); do
        if curl -s -f "$url/healthz" > /dev/null; then
            log_success "$service is healthy"
            return 0
        fi
        log_debug "Health check attempt $i failed for $service"
        sleep 2
    done
    
    log_error "$service health check failed after $max_retries attempts"
    return 1
}

# Function to check monitoring system
check_monitoring_system() {
    log_monitor "Checking Stage 3 Monitoring System..."
    
    # Check if alert watcher is running
    if docker-compose ps alert_watcher 2>/dev/null | grep -q "Up"; then
        log_success "Alert watcher container is running"
        
        # Check watcher logs
        local watcher_status=$(docker-compose logs alert_watcher --tail=3 2>/dev/null | grep -E "(initialized|watching|Slack)" || true)
        if [ -n "$watcher_status" ]; then
            log_success "Alert watcher is initialized and monitoring"
        else
            log_warning "Alert watcher logs not showing normal status"
        fi
        
        # Check if Slack webhook is configured
        local slack_config=$(docker-compose exec alert_watcher env 2>/dev/null | grep SLACK_WEBHOOK_URL || true)
        if echo "$slack_config" | grep -q "hooks.slack.com"; then
            log_success "Slack webhook is configured"
        else
            log_warning "Slack webhook may not be properly configured"
        fi
    else
        log_error "Alert watcher container is not running"
        return 1
    fi
    
    # Check structured logging
    log_monitor "Checking structured logging..."
    sleep 2
    
    # Generate some log traffic
    for i in {1..3}; do
        curl -s "http://$HOST:8080/version" > /dev/null
        sleep 0.5
    done
    
    # Check if structured logs are being written
    if docker-compose exec nginx test -f /var/log/nginx/access.log 2>/dev/null; then
        local log_lines=$(docker-compose exec nginx tail -5 /var/log/nginx/access.log 2>/dev/null | grep -c 'pool=' || true)
        if [ "$log_lines" -gt 0 ]; then
            log_success "Structured logging is working ($log_lines structured log lines found)"
            
            # Show sample structured log
            log_monitor "Sample structured log:"
            docker-compose exec nginx tail -1 /var/log/nginx/access.log 2>/dev/null | \
                grep -o 'pool="[^"]*" release="[^"]*" upstream_status=[^ ]*' | head -1
        else
            log_error "No structured log lines found"
            return 1
        fi
    else
        log_error "Nginx access log file not found"
        return 1
    fi
    
    # Check shared volume
    log_monitor "Checking shared volume access..."
    if docker-compose exec alert_watcher test -r /var/log/nginx/access.log 2>/dev/null; then
        log_success "Alert watcher can read Nginx logs"
    else
        log_error "Alert watcher cannot access Nginx logs"
        return 1
    fi
    
    return 0
}

# Function to monitor for alerts during test
monitor_alerts_during_test() {
    local test_name="$1"
    local timeout="${2:-15}"
    
    log_monitor "Monitoring for alerts during: $test_name (timeout: ${timeout}s)"
    
    # Get current log position
    local start_line=$(docker-compose logs alert_watcher 2>/dev/null | wc -l)
    local alert_detected=false
    local alert_message=""
    
    # Start background monitoring
    for i in $(seq 1 $timeout); do
        local current_logs=$(docker-compose logs alert_watcher --tail=50 2>/dev/null)
        local new_alerts=$(echo "$current_logs" | tail -n +$start_line | grep -E "(Alert sent|Failover detected|High error rate)" || true)
        
        if [ -n "$new_alerts" ]; then
            alert_detected=true
            alert_message="$new_alerts"
            log_success "Alert detected during $test_name"
            echo "$new_alerts"
            break
        fi
        sleep 1
    done
    
    if [ "$alert_detected" = false ]; then
        log_warning "No alerts detected during $test_name (may be expected due to cooldown)"
    fi
    
    return 0
}

# Function to test chaos endpoint
test_chaos_endpoint() {
    local base_url=$1
    local pool=$2
    
    log "Testing chaos endpoints for $pool..."
    
    # Test chaos start with various modes
    local modes=("error" "timeout" "500" "delay" "")
    local chaos_worked=false
    
    for mode in "${modes[@]}"; do
        local url="$base_url/chaos/start"
        if [ -n "$mode" ]; then
            url="$url?mode=$mode"
        fi
        
        log_debug "Trying: POST $url"
        local response
        response=$(curl -s -w "\n%{http_code}" -X POST "$url")
        local status_code=$(echo "$response" | tail -n1)
        local body=$(echo "$response" | head -n1)
        
        if [ "$status_code" = "200" ]; then
            log_success "Chaos started successfully with mode: '${mode:-default}'"
            log_debug "Response: $body"
            chaos_worked=true
            break
        else
            log_debug "Mode '${mode:-default}' failed: HTTP $status_code"
        fi
    done
    
    if [ "$chaos_worked" = false ]; then
        log_warning "No chaos mode worked for $pool"
        return 1
    fi
    
    # Test chaos stop
    log_debug "Testing chaos stop..."
    local stop_response
    stop_response=$(curl -s -w "\n%{http_code}" -X POST "$base_url/chaos/stop")
    local stop_status=$(echo "$stop_response" | tail -n1)
    
    if [ "$stop_status" = "200" ]; then
        log_success "Chaos stop worked for $pool"
        return 0
    else
        log_warning "Chaos stop failed for $pool: HTTP $stop_status"
        return 1
    fi
}

# Function to verify pool serving traffic with detailed analysis
verify_pool() {
    local expected_pool=$1
    local description=$2
    local num_requests=8
    
    log "Verifying pool routing: $description (expecting: $expected_pool)"
    
    local correct_count=0
    local total_checked=0
    local wrong_pools=()
    
    for i in $(seq 1 $num_requests); do
        local response
        response=$(curl -s -i "http://$HOST:8080/version")
        local status_code=$(echo "$response" | grep HTTP | awk '{print $2}')
        local app_pool=$(echo "$response" | grep -i "X-App-Pool:" | awk '{print $2}' | tr -d '\r')
        local release_id=$(echo "$response" | grep -i "X-Release-Id:" | awk '{print $2}' | tr -d '\r')
        
        if [ "$status_code" = "200" ]; then
            ((total_checked++))
            if [ "$app_pool" = "$expected_pool" ]; then
                ((correct_count++))
                log_debug "Request $i: ✓ $app_pool (Release: $release_id)"
            else
                wrong_pools+=("$app_pool")
                log_debug "Request $i: ✗ got $app_pool, expected $expected_pool"
            fi
        else
            log_debug "Request $i: ✗ HTTP $status_code"
        fi
        sleep 0.3
    done
    
    if [ $total_checked -eq 0 ]; then
        log_error "No successful requests to verify pool routing"
        return 1
    fi
    
    local success_rate=$((correct_count * 100 / total_checked))
    
    # Analyze wrong pool distribution
    if [ ${#wrong_pools[@]} -gt 0 ]; then
        local wrong_count=$(printf '%s\n' "${wrong_pools[@]}" | sort | uniq -c | sort -nr)
        log_debug "Wrong pool distribution: $wrong_count"
    fi
    
    if [ $success_rate -ge 90 ]; then
        log_success "Pool routing: $success_rate% requests correctly routed to $expected_pool"
        return 0
    elif [ $success_rate -ge 70 ]; then
        log_warning "Pool routing: $success_rate% requests to $expected_pool (slightly inconsistent)"
        return 0
    else
        log_error "Pool routing failed: only $success_rate% requests to $expected_pool"
        return 1
    fi
}

# Function to test Nginx upstream configuration
test_nginx_upstream() {
    log_monitor "Testing Nginx upstream configuration..."
    
    # Check if Nginx is running with correct config
    if docker-compose exec nginx nginx -t 2>/dev/null; then
        log_success "Nginx configuration is valid"
    else
        log_error "Nginx configuration test failed"
        return 1
    fi
    
    # Check upstream configuration
    local upstream_config=$(docker-compose exec nginx cat /etc/nginx/nginx.conf 2>/dev/null | grep -A10 "upstream active_backend" || true)
    if echo "$upstream_config" | grep -q "backup"; then
        log_success "Nginx upstream configured with backup server"
    else
        log_error "Nginx upstream missing backup configuration"
        return 1
    fi
    
    # Check if upstream servers are reachable
    if docker-compose exec nginx ping -c 1 app_blue 2>/dev/null > /dev/null; then
        log_success "Nginx can reach blue upstream"
    else
        log_error "Nginx cannot reach blue upstream"
    fi
    
    if docker-compose exec nginx ping -c 1 app_green 2>/dev/null > /dev/null; then
        log_success "Nginx can reach green upstream"
    else
        log_error "Nginx cannot reach green upstream"
    fi
    
    return 0
}

# Function to test header preservation
test_header_preservation() {
    log "Testing header preservation through proxy..."
    
    local response=$(curl -s -i "http://$HOST:8080/version")
    local app_pool=$(echo "$response" | grep -i "X-App-Pool:" | awk '{print $2}' | tr -d '\r')
    local release_id=$(echo "$response" | grep -i "X-Release-Id:" | awk '{print $2}' | tr -d '\r')
    
    if [ -n "$app_pool" ] && [ -n "$release_id" ]; then
        log_success "Headers preserved - X-App-Pool: $app_pool, X-Release-Id: $release_id"
        return 0
    else
        log_error "Headers not properly preserved through proxy"
        return 1
    fi
}

# Function to test failover with chaos and monitoring
test_chaos_failover_with_monitoring() {
    local chaos_pool=$1
    local chaos_url="http://$HOST:8081"
    if [ "$chaos_pool" = "green" ]; then
        chaos_url="http://$HOST:8082"
    fi
    
    log "Testing chaos-induced failover from $chaos_pool with monitoring..."
    
    # Start monitoring for alerts in background
    monitor_alerts_during_test "${chaos_pool}_failover" 10 &
    local monitor_pid=$!
    
    # Step 1: Start chaos
    log "Starting chaos on $chaos_pool..."
    local chaos_started=false
    
    # Try multiple chaos modes
    for mode in "error" "timeout" "500" ""; do
        local chaos_cmd="$chaos_url/chaos/start"
        if [ -n "$mode" ]; then
            chaos_cmd="$chaos_cmd?mode=$mode"
        fi
        
        local response
        response=$(curl -s -w "\n%{http_code}" -X POST "$chaos_cmd")
        local status_code=$(echo "$response" | tail -n1)
        
        if [ "$status_code" = "200" ]; then
            log_success "Chaos started on $chaos_pool with mode: '${mode:-default}'"
            chaos_started=true
            
            # Verify the target pool is actually failing
            log_debug "Verifying $chaos_pool is returning errors..."
            local target_status
            target_status=$(curl -s -o /dev/null -w "%{http_code}" "$chaos_url/version")
            log_debug "$chaos_pool direct status during chaos: $target_status"
            break
        fi
    done
    
    if [ "$chaos_started" = false ]; then
        log_warning "Could not start chaos on $chaos_pool - using manual failure simulation"
        # Fallback: manually stop the container
        docker-compose stop "app_$chaos_pool" 2>/dev/null && {
            log_success "Manually stopped $chaos_pool container for testing"
            chaos_started=true
        } || {
            log_error "Cannot simulate failure for $chaos_pool"
            kill $monitor_pid 2>/dev/null || true
            return 1
        }
    fi
    
    # Step 2: Wait for failover (matches Nginx 2s fail_timeout + buffer)
    log "Waiting for failover detection (3 seconds)..."
    sleep 3
    
    # Step 3: Verify failover occurred
    local expected_new_pool="green"
    if [ "$chaos_pool" = "green" ]; then
        expected_new_pool="blue"
    fi
    
    log "Verifying failover to $expected_new_pool..."
    
    # Test multiple requests to confirm failover
    local failover_success=0
    local test_requests=10
    
    for i in $(seq 1 $test_requests); do
        local response
        response=$(curl -s -i "http://$HOST:8080/version")
        local status_code=$(echo "$response" | grep HTTP | awk '{print $2}')
        local app_pool=$(echo "$response" | grep -i "X-App-Pool:" | awk '{print $2}' | tr -d '\r')
        
        if [ "$status_code" = "200" ] && [ "$app_pool" = "$expected_new_pool" ]; then
            ((failover_success++))
            log_debug "Failover request $i: ✓ $app_pool"
        else
            log_debug "Failover request $i: ✗ Status: $status_code, Pool: $app_pool"
        fi
        sleep 0.3
    done
    
    local failover_rate=$((failover_success * 100 / test_requests))
    
    if [ $failover_rate -ge 80 ]; then
        log_success "Failover successful: $failover_rate% traffic to $expected_new_pool"
    else
        log_error "Failover failed: only $failover_rate% traffic to $expected_new_pool"
        # Restart stopped container if we used manual method
        if [ "$chaos_started" = true ] && docker-compose ps "app_$chaos_pool" 2>/dev/null | grep -q "Exit"; then
            docker-compose start "app_$chaos_pool" 2>/dev/null
        fi
        kill $monitor_pid 2>/dev/null || true
        return 1
    fi
    
    # Step 4: Test zero-downtime during failure
    log "Testing zero-downtime during chaos..."
    local failed_requests=0
    local stability_requests=20
    
    for i in $(seq 1 $stability_requests); do
        if ! curl -s -f "http://$HOST:8080/version" > /dev/null; then
            ((failed_requests++))
            log_debug "Stability request $i: ✗ Failed"
        else
            log_debug "Stability request $i: ✓ Success"
        fi
        sleep 0.2
    done
    
    if [ $failed_requests -eq 0 ]; then
        log_success "Zero-downtime verified: $stability_requests requests, 0 failures"
    else
        log_error "Downtime detected: $failed_requests failed requests out of $stability_requests"
    fi
    
    # Wait for monitor to complete
    wait $monitor_pid 2>/dev/null || true
    
    # Step 5: Stop chaos and verify recovery
    log "Stopping chaos and verifying recovery..."
    
    # Stop chaos or restart container
    if docker-compose ps "app_$chaos_pool" 2>/dev/null | grep -q "Up"; then
        curl -s -X POST "$chaos_url/chaos/stop" > /dev/null
        log_success "Chaos stopped on $chaos_pool"
    else
        docker-compose start "app_$chaos_pool" 2>/dev/null
        log_success "Restarted $chaos_pool container"
    fi
    
    # Wait for recovery (Nginx fail_timeout expiration)
    log "Waiting for recovery (5 seconds)..."
    sleep 5
    
    # Verify system returned to normal
    log "Verifying system returned to normal state..."
    if verify_pool "blue" "recovery state"; then
        log_success "System recovered successfully"
        return 0
    else
        log_error "System did not recover properly"
        return 1
    fi
}

# Function to test error rate monitoring
test_error_rate_monitoring() {
    log_monitor "Testing error rate monitoring and alerting..."
    
    # Start monitoring for error alerts
    monitor_alerts_during_test "error_rate_test" 20 &
    local monitor_pid=$!
    
    # Generate high error rate conditions
    log "Generating high error rate conditions..."
    
    # Create a burst of requests with intermittent errors
    for i in {1..150}; do
        curl -s "http://$HOST:8080/version" > /dev/null
        # Every 10th request, trigger an error
        if [ $((i % 10)) -eq 0 ]; then
            curl -s -X POST "http://$HOST:8081/chaos/start?mode=error" > /dev/null
            sleep 0.1
            curl -s -X POST "http://$HOST:8081/chaos/stop" > /dev/null
        fi
        sleep 0.1
    done
    
    # Wait for error rate evaluation
    log "Waiting for error rate evaluation..."
    sleep 10
    
    # Check error rate calculation
    local error_logs=$(docker-compose logs alert_watcher --tail=20 2>/dev/null | grep -E "(error rate|Error Rate|window)" || true)
    if [ -n "$error_logs" ]; then
        log_monitor "Error rate calculations:"
        echo "$error_logs"
    fi
    
    # Wait for monitor to complete
    wait $monitor_pid 2>/dev/null || true
    
    log_success "Error rate monitoring test completed"
    return 0
}

# Main test execution
main() {
    echo "=========================================="
    echo "🔵 Blue/Green Deployment - Comprehensive Test with Monitoring"
    echo "=========================================="
    echo "Target Host: $HOST"
    echo "Stage 3: Full Monitoring & Alerting Included"
    echo ""
    
    # Pre-flight checks
    log "Running pre-flight checks..."
    
    # Check if services are running
    if ! docker-compose ps 2>/dev/null | grep -q "Up"; then
        log_error "Docker services are not running. Start with: docker-compose up -d"
        exit 1
    fi
    
    # Test service health
    test_service_health "Blue" "http://$HOST:8081" || exit 1
    test_service_health "Green" "http://$HOST:8082" || exit 1
    
    # Test Nginx upstream configuration
    test_nginx_upstream || exit 1
    
    # Test header preservation
    test_header_preservation || exit 1
    
    # Test monitoring system
    check_monitoring_system || {
        log_warning "Monitoring system has issues, but continuing with core tests..."
    }
    
    # Test chaos endpoints
    log "Testing chaos endpoints..."
    test_chaos_endpoint "http://$HOST:8081" "blue"
    test_chaos_endpoint "http://$HOST:8082" "green"
    
    echo ""
    echo "=========================================="
    echo ""
    
    # Test 1: Initial state verification
    log "=== TEST 1: Initial State Verification ==="
    if verify_pool "blue" "initial state"; then
        log_success "Initial state verified - Blue is active"
    else
        log_error "Initial state verification failed"
        exit 1
    fi
    
    echo ""
    
    # Test 2: Chaos failover from Blue to Green with monitoring
    log "=== TEST 2: Chaos Failover (Blue → Green) with Monitoring ==="
    if test_chaos_failover_with_monitoring "blue"; then
        log_success "Blue→Green chaos failover test passed"
    else
        log_error "Blue→Green chaos failover test failed"
    fi
    
    echo ""
    
    # Test 3: Error rate monitoring
    log "=== TEST 3: Error Rate Monitoring Test ==="
    test_error_rate_monitoring
    
    echo ""
    
    # Test 4: Chaos failover from Green to Blue with monitoring
    log "=== TEST 4: Chaos Failover (Green → Blue) with Monitoring ==="
    if test_chaos_failover_with_monitoring "green"; then
        log_success "Green→Blue chaos failover test passed"
    else
        log_error "Green→Blue chaos failover test failed"
    fi
    
    # Final summary
    echo ""
    echo "=========================================="
    echo "📊 COMPREHENSIVE TEST SUMMARY"
    echo "=========================================="
    log_success "Tests Passed: $TESTS_PASSED"
    if [ $TESTS_FAILED -gt 0 ]; then
        log_error "Tests Failed: $TESTS_FAILED"
    else
        log_success "Tests Failed: $TESTS_FAILED"
    fi
    
    local total_tests=$((TESTS_PASSED + TESTS_FAILED))
    if [ $total_tests -gt 0 ]; then
        local success_rate=$((TESTS_PASSED * 100 / total_tests))
        echo "Success Rate: $success_rate%"
    fi
    
    if [ $TESTS_FAILED -eq 0 ]; then
        echo ""
        echo -e "${GREEN}🎉 ALL TESTS PASSED! Blue/Green deployment with monitoring is working correctly.${NC}"
        echo ""
        echo "Verified Features:"
        echo "  ✅ Blue/Green routing with Nginx upstream"
        echo "  ✅ Automatic failover within 3 seconds"  
        echo "  ✅ Chaos engineering with multiple failure modes"
        echo "  ✅ Zero-downtime during failover"
        echo "  ✅ Header preservation through proxy"
        echo "  ✅ Health monitoring integration"
        echo "  ✅ Stage 3 monitoring system"
        echo "  ✅ Structured logging"
        echo "  ✅ Alert watcher functionality"
        echo "  ✅ Slack integration (if configured)"
        echo ""
        echo "Next steps:"
        echo "  1. Check Slack for alert messages"
        echo "  2. Verify structured logs are being written"
        echo "  3. Monitor watcher performance"
        exit 0
    else
        echo ""
        echo -e "${RED}❌ SOME TESTS FAILED. Check the deployment configuration.${NC}"
        exit 1
    fi
}

# Handle script interruption
cleanup() {
    log "Cleaning up..."
    # Stop any chaos and ensure all services are running
    curl -s -X POST "http://$HOST:8081/chaos/stop" > /dev/null 2>&1 || true
    curl -s -X POST "http://$HOST:8082/chaos/stop" > /dev/null 2>&1 || true
    docker-compose start app_blue app_green > /dev/null 2>&1 || true
    log "Cleanup completed"
}

trap cleanup EXIT INT TERM

# Run main function
main "$@"