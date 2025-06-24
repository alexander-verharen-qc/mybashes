#!/bin/bash
# 04_monitor_realtime.sh - Real-time monitoring during changes
# Keep this running in a separate terminal during implementation

set -euo pipefail

# Configuration
REFRESH_INTERVAL=10
ALERT_THRESHOLD_DNS_CPU=80
ALERT_THRESHOLD_RESTART_RATE=5

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Function to get DNS CPU usage
get_dns_cpu() {
    if kubectl top pods -n kube-system &>/dev/null; then
        kubectl top pods -n kube-system -l k8s-app=kube-dns --no-headers 2>/dev/null | \
            awk '{gsub(/m/,"",$2); sum+=$2; count++} END {if (count>0) print int(sum/count/10) "%"; else print "N/A"}'
    else
        echo "N/A"
    fi
}

# Function to count failing pods
count_failing_pods() {
    kubectl get pods -A --no-headers 2>/dev/null | \
        grep -E "CrashLoopBackOff|Error|ImagePullBackOff" | wc -l || echo 0
}

# Function to check specific service health
check_service_health() {
    local service=$1
    local namespace=$2
    local status=$(kubectl get pods -n "$namespace" -l app="$service" --no-headers 2>/dev/null | \
        awk '{if ($3 == "Running") r++; else f++} END {print r "/" (r+f)}')
    echo "${status:-0/0}"
}

# Main monitoring loop
clear
echo "=== DNS Remediation Real-time Monitor ==="
echo "Press Ctrl+C to stop"
echo

LOOP_COUNT=0
LAST_FAILING_COUNT=0

while true; do
    # Clear screen every 10 loops to prevent scrolling
    if [ $((LOOP_COUNT % 10)) -eq 0 ]; then
        clear
        echo "=== DNS Remediation Real-time Monitor ==="
        echo "Time: $(date '+%Y-%m-%d %H:%M:%S %Z')"
        echo "Refresh: ${REFRESH_INTERVAL}s | Alerts: DNS CPU>${ALERT_THRESHOLD_DNS_CPU}% | Restart Rate>${ALERT_THRESHOLD_RESTART_RATE}/min"
        echo "========================================="
    fi
    
    # DNS Status
    echo -e "\n--- DNS Infrastructure ---"
    DNS_PODS=$(kubectl get pods -n kube-system -l k8s-app=kube-dns --no-headers 2>/dev/null | wc -l | tr -d '\n' || echo 0)
    DNS_RUNNING=$(kubectl get pods -n kube-system -l k8s-app=kube-dns --no-headers 2>/dev/null | grep -c Running | tr -d '\n' || echo 0)
    DNS_CPU=$(get_dns_cpu)
    
    if [[ "$DNS_RUNNING" =~ ^[0-9]+$ ]] && [[ "$DNS_PODS" =~ ^[0-9]+$ ]] && [ "$DNS_RUNNING" -eq "$DNS_PODS" ]; then
        echo -e "DNS Pods: ${GREEN}$DNS_RUNNING/$DNS_PODS Running${NC}"
    else
        echo -e "DNS Pods: ${RED}$DNS_RUNNING/$DNS_PODS Running${NC} ⚠️"
    fi
    
    # Check DNS CPU
    DNS_CPU_NUM=$(echo $DNS_CPU | grep -o '[0-9]*' || echo 0)
    # Ensure DNS_CPU_NUM is not empty and is numeric
    if [[ "$DNS_CPU_NUM" =~ ^[0-9]+$ ]] && [ "$DNS_CPU_NUM" -gt "$ALERT_THRESHOLD_DNS_CPU" ]; then
        echo -e "DNS CPU: ${RED}$DNS_CPU${NC} ⚠️ HIGH"
    else
        echo -e "DNS CPU: ${GREEN}$DNS_CPU${NC}"
    fi
    
    # Show individual DNS pod status
    kubectl get pods -n kube-system -l k8s-app=kube-dns --no-headers 2>/dev/null | \
        awk '{printf "  %-40s %s\n", $1, $3}'
    
    # Failed Pods
    echo -e "\n--- Failed Pods ---"
    CURRENT_FAILING=$(count_failing_pods)
    # Ensure CURRENT_FAILING and LAST_FAILING_COUNT are numeric
    [[ "$CURRENT_FAILING" =~ ^[0-9]+$ ]] || CURRENT_FAILING=0
    [[ "$LAST_FAILING_COUNT" =~ ^[0-9]+$ ]] || LAST_FAILING_COUNT=0
    RESTART_RATE=$((CURRENT_FAILING - LAST_FAILING_COUNT))
    
    if [[ "$RESTART_RATE" =~ ^-?[0-9]+$ ]] && [ "$RESTART_RATE" -gt "$ALERT_THRESHOLD_RESTART_RATE" ]; then
        echo -e "Total Failed: ${RED}$CURRENT_FAILING${NC} (↑$RESTART_RATE) ⚠️ SPIKE"
    elif [[ "$CURRENT_FAILING" =~ ^[0-9]+$ ]] && [ "$CURRENT_FAILING" -gt 20 ]; then
        echo -e "Total Failed: ${YELLOW}$CURRENT_FAILING${NC}"
    else
        echo -e "Total Failed: ${GREEN}$CURRENT_FAILING${NC}"
    fi
    
    # Service Health
    echo -e "\n--- Critical Services ---"
    
    # Special Order Cost Service
    SOCS_HEALTH=$(check_service_health "special-order-cost-svc" "vendor-production")
    if [[ "$SOCS_HEALTH" == *"0/"* ]] || [[ "$SOCS_HEALTH" == "0/0" ]]; then
        echo -e "special-order-cost-svc: ${RED}$SOCS_HEALTH${NC} ❌"
    else
        echo -e "special-order-cost-svc: ${GREEN}$SOCS_HEALTH${NC}"
    fi
    
    # Pro MRO Pricing Service
    PMPS_HEALTH=$(check_service_health "pro-mro-pricing-svc" "pricing-production")
    if [[ "$PMPS_HEALTH" == *"0/"* ]] || [[ "$PMPS_HEALTH" == "0/0" ]]; then
        echo -e "pro-mro-pricing-svc: ${RED}$PMPS_HEALTH${NC} ❌"
    else
        echo -e "pro-mro-pricing-svc: ${GREEN}$PMPS_HEALTH${NC}"
    fi
    
    # Dead Letter Projector
    DLP_HEALTH=$(check_service_health "dead-letter-projector" "vendor-production")
    if [[ "$DLP_HEALTH" == *"0/"* ]] || [[ "$DLP_HEALTH" == "0/0" ]]; then
        echo -e "dead-letter-projector: ${RED}$DLP_HEALTH${NC} ❌"
    else
        echo -e "dead-letter-projector: ${GREEN}$DLP_HEALTH${NC}"
    fi
    
    # Recent Events
    echo -e "\n--- Recent Events (last 60s) ---"
    kubectl get events -A --field-selector type=Warning --sort-by='.lastTimestamp' 2>/dev/null | \
        grep -E "(DNS|dns|Cassandra|cassandra|Failed|CrashLoop)" | \
        tail -3 | awk '{print $1, $2, $5, $6}' || echo "No warning events"
    
    # Alert Summary
    echo -e "\n--- Alert Status ---"
    ALERTS=0
    if [[ "$DNS_CPU_NUM" =~ ^[0-9]+$ ]] && [ "$DNS_CPU_NUM" -gt "$ALERT_THRESHOLD_DNS_CPU" ]; then
        echo -e "${RED}⚠️  DNS CPU is above ${ALERT_THRESHOLD_DNS_CPU}%${NC}"
        ALERTS=$((ALERTS + 1))
    fi
    if [[ "$RESTART_RATE" =~ ^-?[0-9]+$ ]] && [ "$RESTART_RATE" -gt "$ALERT_THRESHOLD_RESTART_RATE" ]; then
        echo -e "${RED}⚠️  Pod restart rate spike detected${NC}"
        ALERTS=$((ALERTS + 1))
    fi
    if [[ "$DNS_RUNNING" =~ ^[0-9]+$ ]] && [[ "$DNS_PODS" =~ ^[0-9]+$ ]] && [ "$DNS_RUNNING" -ne "$DNS_PODS" ]; then
        echo -e "${RED}⚠️  Not all DNS pods are running${NC}"
        ALERTS=$((ALERTS + 1))
    fi
    if [ "$ALERTS" -eq 0 ]; then
        echo -e "${GREEN}✓ All systems normal${NC}"
    fi
    
    # Update counters
    LAST_FAILING_COUNT=$CURRENT_FAILING
    LOOP_COUNT=$((LOOP_COUNT + 1))
    
    # Sleep
    sleep $REFRESH_INTERVAL
done