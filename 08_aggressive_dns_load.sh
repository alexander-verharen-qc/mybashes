#!/bin/bash
# 08_aggressive_dns_load.sh - Aggressive DNS load test to reach 5-10% CPU utilization
# Uses parallel dig queries with minimal delays for maximum throughput

set -euo pipefail

# Configuration
DEFAULT_DURATION=300
DEFAULT_PODS=100
DEFAULT_THREADS_PER_POD=5

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# Usage
usage() {
    cat << EOF
Usage: $0 [OPTIONS]

Aggressive DNS Load Test - Targets 5-10% CPU utilization on kube-dns

OPTIONS:
    -d, --duration <seconds>    Test duration (default: $DEFAULT_DURATION)
    -p, --pods <number>        Number of loader pods (default: $DEFAULT_PODS)
    -t, --threads <number>     Threads per pod (default: $DEFAULT_THREADS_PER_POD)
    -n, --namespace <name>     Namespace for test (default: default)
    -m, --monitor             Enable real-time monitoring
    -h, --help               Display this help

EXAMPLES:
    # Standard aggressive test
    $0

    # Ultra-aggressive test
    $0 -p 150 -t 10 -m

    # Quick test
    $0 -d 60 -p 50

EOF
    exit 1
}

# Parse arguments
DURATION=$DEFAULT_DURATION
PODS=$DEFAULT_PODS
THREADS=$DEFAULT_THREADS_PER_POD
NAMESPACE="default"
ENABLE_MONITOR=false

while [[ $# -gt 0 ]]; do
    case $1 in
        -d|--duration) DURATION="$2"; shift 2 ;;
        -p|--pods) PODS="$2"; shift 2 ;;
        -t|--threads) THREADS="$2"; shift 2 ;;
        -n|--namespace) NAMESPACE="$2"; shift 2 ;;
        -m|--monitor) ENABLE_MONITOR=true; shift ;;
        -h|--help) usage ;;
        *) echo -e "${RED}Unknown option: $1${NC}"; usage ;;
    esac
done

# Verify cluster
CURRENT_CONTEXT=$(kubectl config current-context)
echo -e "${BLUE}=== Aggressive DNS Load Test ===${NC}"
echo "Target cluster: $CURRENT_CONTEXT"
echo ""

# Get initial state
echo -e "${BLUE}Initial DNS State:${NC}"
INITIAL_PODS=$(kubectl get pods -n kube-system -l k8s-app=kube-dns --no-headers | wc -l)
INITIAL_CPU=$(kubectl top pods -n kube-system -l k8s-app=kube-dns --no-headers 2>/dev/null | \
    awk '{gsub(/m/,"",$2); sum+=$2; count++} END {if (count>0) print int(sum/count/10); else print 0}' || echo 0)

echo "DNS Pods: $INITIAL_PODS"
echo "Average CPU: ${INITIAL_CPU}%"
kubectl top pods -n kube-system -l k8s-app=kube-dns 2>/dev/null || true
echo ""

# Create aggressive test job
JOB_NAME="aggressive-dns-load-$(date +%s)"
TOTAL_THREADS=$((PODS * THREADS))

echo -e "${BLUE}Deploying aggressive load test...${NC}"
echo "Configuration:"
echo "  Duration: ${DURATION}s"
echo "  Loader Pods: $PODS"
echo "  Threads per Pod: $THREADS"
echo "  Total Threads: $TOTAL_THREADS"
echo "  Estimated QPS: ~$(($TOTAL_THREADS * 100))"
echo ""

# Create the job
cat <<'EOF' | sed "s/{{JOB_NAME}}/$JOB_NAME/g" | \
    sed "s/{{NAMESPACE}}/$NAMESPACE/g" | \
    sed "s/{{PODS}}/$PODS/g" | \
    sed "s/{{DURATION}}/$DURATION/g" | \
    sed "s/{{THREADS}}/$THREADS/g" | \
    kubectl apply -f -
apiVersion: batch/v1
kind: Job
metadata:
  name: {{JOB_NAME}}
  namespace: {{NAMESPACE}}
  labels:
    app: aggressive-dns-load
spec:
  parallelism: {{PODS}}
  completions: {{PODS}}
  backoffLimit: 1
  ttlSecondsAfterFinished: 300
  template:
    metadata:
      labels:
        app: aggressive-dns-load
        job: {{JOB_NAME}}
    spec:
      restartPolicy: Never
      containers:
      - name: dns-hammer
        image: tutum/dnsutils:latest
        command: ["/bin/bash", "-c"]
        args:
        - |
          echo "Starting aggressive DNS load on $(hostname)"
          
          # Domains to hammer
          DOMAINS=(
            "kubernetes.default.svc.cluster.local"
            "kube-dns.kube-system.svc.cluster.local"
            "metrics-server.kube-system.svc.cluster.local"
            "cassandra.cassandra.svc.cluster.local"
            "cassandra-0.cassandra.cassandra.svc.cluster.local"
            "cassandra-1.cassandra.cassandra.svc.cluster.local"
            "special-order-cost-svc.vendor-production.svc.cluster.local"
            "pro-mro-pricing-svc.pricing-production.svc.cluster.local"
            "nonexistent-$(date +%N).invalid"
            "random-${RANDOM}.test.local"
          )
          
          # Function to hammer DNS
          hammer_dns() {
            local thread_id=$1
            local end_time=$(($(date +%s) + {{DURATION}}))
            local queries=0
            
            while [ $(date +%s) -lt $end_time ]; do
              for domain in "${DOMAINS[@]}"; do
                # Rapid-fire queries with no delay
                dig @kube-dns.kube-system.svc.cluster.local $domain +short +tries=1 +time=1 >/dev/null 2>&1 &
                dig @10.0.0.10 $domain A +short +tries=1 +time=1 >/dev/null 2>&1 &
                nslookup $domain >/dev/null 2>&1 &
                host $domain >/dev/null 2>&1 &
                queries=$((queries + 4))
                
                # Batch background jobs to prevent overwhelming
                if [ $((queries % 100)) -eq 0 ]; then
                  wait
                fi
              done
            done
            
            wait
            echo "Thread $thread_id completed: ~$queries queries"
          }
          
          # Launch parallel threads
          echo "Launching {{THREADS}} threads..."
          for i in $(seq 1 {{THREADS}}); do
            hammer_dns $i &
          done
          
          # Wait for all threads
          wait
          echo "All threads completed"
        resources:
          requests:
            cpu: "100m"
            memory: "64Mi"
          limits:
            cpu: "500m"
            memory: "128Mi"
EOF

# Start monitoring if requested
if [ "$ENABLE_MONITOR" = true ]; then
    echo -e "${BLUE}Starting monitor...${NC}"
    ./04_monitor_realtime.sh &
    MONITOR_PID=$!
fi

# Wait for pods to start
echo -e "${BLUE}Waiting for pods to start (this may take a moment with $PODS pods)...${NC}"
sleep 10

# Monitor the load test
echo -e "${BLUE}Load test running...${NC}"
START_TIME=$(date +%s)
MAX_CPU=0
MIN_CPU=100
CPU_SAMPLES=()

while true; do
    ELAPSED=$(($(date +%s) - START_TIME))
    
    # Get metrics
    RUNNING=$(kubectl get pods -n $NAMESPACE -l job=$JOB_NAME --field-selector=status.phase=Running --no-headers 2>/dev/null | wc -l || echo 0)
    COMPLETED=$(kubectl get job $JOB_NAME -n $NAMESPACE -o jsonpath='{.status.succeeded}' 2>/dev/null || echo 0)
    
    # DNS metrics
    DNS_PODS=$(kubectl get pods -n kube-system -l k8s-app=kube-dns --no-headers | wc -l)
    DNS_CPU=$(kubectl top pods -n kube-system -l k8s-app=kube-dns --no-headers 2>/dev/null | \
        awk '{gsub(/m/,"",$2); sum+=$2; count++} END {if (count>0) print int(sum/count/10); else print 0}' || echo 0)
    
    # Track CPU stats
    if [[ "$DNS_CPU" =~ ^[0-9]+$ ]] && [ "$DNS_CPU" -gt 0 ]; then
        CPU_SAMPLES+=($DNS_CPU)
        [[ "$MAX_CPU" =~ ^[0-9]+$ ]] && [ "$DNS_CPU" -gt "$MAX_CPU" ] && MAX_CPU=$DNS_CPU
        [[ "$MIN_CPU" =~ ^[0-9]+$ ]] && [ "$DNS_CPU" -lt "$MIN_CPU" ] && MIN_CPU=$DNS_CPU
    fi
    
    # Color code CPU usage
    if [[ "$DNS_CPU" =~ ^[0-9]+$ ]] && [ "$DNS_CPU" -ge 10 ]; then
        CPU_COLOR="${GREEN}"
        CPU_STATUS="✓ TARGET"
    elif [[ "$DNS_CPU" =~ ^[0-9]+$ ]] && [ "$DNS_CPU" -ge 5 ]; then
        CPU_COLOR="${YELLOW}"
        CPU_STATUS="→ CLOSE"
    else
        CPU_COLOR="${RED}"
        CPU_STATUS="↑ MORE"
    fi
    
    # Display progress
    printf "\r${YELLOW}[%3d/%3ds]${NC} Running: %d, Done: %d | DNS: %d pods @ ${CPU_COLOR}%d%%${NC} (min:%d%% max:%d%%) %s" \
        "$ELAPSED" "$DURATION" "$RUNNING" "$COMPLETED" "$DNS_PODS" "$DNS_CPU" "$MIN_CPU" "$MAX_CPU" "$CPU_STATUS"
    
    # Check completion
    [[ "$ELAPSED" =~ ^[0-9]+$ ]] || ELAPSED=0
    [[ "$COMPLETED" =~ ^[0-9]+$ ]] || COMPLETED=0
    if [ "$ELAPSED" -ge "$DURATION" ] || [ "$COMPLETED" -eq "$PODS" ]; then
        echo ""
        break
    fi
    
    sleep 5
done

# Calculate average CPU
if [ ${#CPU_SAMPLES[@]} -gt 0 ]; then
    AVG_CPU=$(printf '%s\n' "${CPU_SAMPLES[@]}" | awk '{sum+=$1} END {print int(sum/NR)}')
else
    AVG_CPU=0
fi

echo ""
echo ""
echo -e "${GREEN}Load test completed!${NC}"
echo ""

# Results summary
echo -e "${BLUE}=== Test Results ===${NC}"
echo "Test Duration: ${DURATION}s"
echo "Loader Pods: $PODS"
echo "Threads per Pod: $THREADS"
echo "Total Threads: $TOTAL_THREADS"
echo ""
echo "DNS CPU Usage:"
echo "  Initial: ${INITIAL_CPU}%"
echo "  Average: ${AVG_CPU}%"
echo "  Minimum: ${MIN_CPU}%"
echo "  Maximum: ${MAX_CPU}%"
echo ""

# Show detailed pod metrics
echo -e "${BLUE}Final DNS Pod Metrics:${NC}"
kubectl top pods -n kube-system -l k8s-app=kube-dns

# Success evaluation
echo ""
[[ "$MAX_CPU" =~ ^[0-9]+$ ]] || MAX_CPU=0
if [ "$MAX_CPU" -ge 10 ]; then
    echo -e "${GREEN}✓ SUCCESS: Achieved target CPU utilization (≥10%)${NC}"
elif [[ "$MAX_CPU" =~ ^[0-9]+$ ]] && [ "$MAX_CPU" -ge 5 ]; then
    echo -e "${YELLOW}◐ PARTIAL: Reached ${MAX_CPU}% CPU (target: 5-10%)${NC}"
else
    echo -e "${RED}✗ INSUFFICIENT: Only reached ${MAX_CPU}% CPU${NC}"
    echo -e "${YELLOW}Consider increasing pods (-p) or threads (-t)${NC}"
fi

# Cleanup
echo ""
echo -e "${YELLOW}Cleaning up...${NC}"
kubectl delete job $JOB_NAME -n $NAMESPACE --wait=false

# Stop monitor
if [ "$ENABLE_MONITOR" = true ] && [ -n "${MONITOR_PID:-}" ]; then
    kill $MONITOR_PID 2>/dev/null || true
fi

echo -e "${GREEN}Done!${NC}"

# Suggestions for next run
if [[ "$MAX_CPU" =~ ^[0-9]+$ ]] && [ "$MAX_CPU" -lt 5 ]; then
    echo ""
    echo -e "${BLUE}To increase load, try:${NC}"
    echo "  $0 -p $((PODS * 2)) -t $THREADS"
    echo "  $0 -p $PODS -t $((THREADS * 2))"
fi