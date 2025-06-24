#!/bin/bash
# 05_dns_load_test.sh - DNS Load Testing Tool for kube-dns HPA validation
# This script generates DNS load to test HPA scaling behavior

set -euo pipefail

# Configuration
DEFAULT_DURATION=300  # 5 minutes
DEFAULT_THREADS=10
DEFAULT_QPS=100
DEFAULT_DOMAINS=(
    "kubernetes.default.svc.cluster.local"
    "kube-dns.kube-system.svc.cluster.local"
    "special-order-cost-svc.vendor-production.svc.cluster.local"
    "pro-mro-pricing-svc.pricing-production.svc.cluster.local"
    "dead-letter-projector.vendor-production.svc.cluster.local"
    "cassandra.cassandra.svc.cluster.local"
)

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# Function to display usage
usage() {
    cat << EOF
Usage: $0 [OPTIONS]

DNS Load Testing Tool for kube-dns HPA validation

OPTIONS:
    -d, --duration <seconds>    Test duration in seconds (default: $DEFAULT_DURATION)
    -t, --threads <number>      Number of concurrent threads (default: $DEFAULT_THREADS)
    -q, --qps <number>         Queries per second per thread (default: $DEFAULT_QPS)
    -n, --namespace <name>      Namespace to run test pods (default: default)
    -m, --monitor              Enable real-time monitoring in parallel
    -h, --help                 Display this help message

EXAMPLES:
    # Run a 5-minute test with default settings
    $0

    # Run a 10-minute high-load test with monitoring
    $0 -d 600 -t 20 -q 200 -m

    # Run a quick 1-minute test
    $0 -d 60 -t 5 -q 50

EOF
    exit 1
}

# Parse command line arguments
DURATION=$DEFAULT_DURATION
THREADS=$DEFAULT_THREADS
QPS=$DEFAULT_QPS
NAMESPACE="default"
ENABLE_MONITOR=false

while [[ $# -gt 0 ]]; do
    case $1 in
        -d|--duration)
            DURATION="$2"
            shift 2
            ;;
        -t|--threads)
            THREADS="$2"
            shift 2
            ;;
        -q|--qps)
            QPS="$2"
            shift 2
            ;;
        -n|--namespace)
            NAMESPACE="$2"
            shift 2
            ;;
        -m|--monitor)
            ENABLE_MONITOR=true
            shift
            ;;
        -h|--help)
            usage
            ;;
        *)
            echo -e "${RED}Unknown option: $1${NC}"
            usage
            ;;
    esac
done

# Validate inputs
if ! [[ "$DURATION" =~ ^[0-9]+$ ]] || [ "$DURATION" -lt 10 ]; then
    echo -e "${RED}Error: Duration must be a number >= 10 seconds${NC}"
    exit 1
fi

if ! [[ "$THREADS" =~ ^[0-9]+$ ]] || [ "$THREADS" -lt 1 ] || [ "$THREADS" -gt 100 ]; then
    echo -e "${RED}Error: Threads must be between 1 and 100${NC}"
    exit 1
fi

if ! [[ "$QPS" =~ ^[0-9]+$ ]] || [ "$QPS" -lt 1 ] || [ "$QPS" -gt 1000 ]; then
    echo -e "${RED}Error: QPS must be between 1 and 1000${NC}"
    exit 1
fi

# Check if we're connected to the right cluster
CURRENT_CONTEXT=$(kubectl config current-context)
if [[ ! "$CURRENT_CONTEXT" =~ "np-quotecenter" ]]; then
    echo -e "${YELLOW}Warning: Current context '$CURRENT_CONTEXT' doesn't appear to be np-quotecenter${NC}"
    echo -n "Continue anyway? (y/N): "
    read -r response
    if [[ ! "$response" =~ ^[Yy]$ ]]; then
        echo "Aborted."
        exit 1
    fi
fi

# Function to create load test job
create_load_test() {
    local job_name="dns-load-test-$(date +%s)"
    local total_qps=$((THREADS * QPS))
    
    echo -e "${BLUE}Creating DNS load test job...${NC}"
    echo "Configuration:"
    echo "  Duration: ${DURATION}s"
    echo "  Threads: $THREADS"
    echo "  QPS per thread: $QPS"
    echo "  Total QPS: $total_qps"
    echo "  Namespace: $NAMESPACE"
    echo ""

    # Create the load test job
    cat <<EOF | kubectl apply -f -
apiVersion: batch/v1
kind: Job
metadata:
  name: $job_name
  namespace: $NAMESPACE
  labels:
    app: dns-load-test
spec:
  ttlSecondsAfterFinished: 600
  parallelism: $THREADS
  completions: $THREADS
  backoffLimit: 3
  template:
    metadata:
      labels:
        app: dns-load-test
    spec:
      restartPolicy: Never
      containers:
      - name: dns-load
        image: busybox:latest
        command: ["/bin/sh", "-c"]
        args:
        - |
          echo "Starting DNS load test on pod \$(hostname)"
          DOMAINS="${DEFAULT_DOMAINS[*]}"
          END_TIME=\$(($(date +%s) + $DURATION))
          QUERY_COUNT=0
          FAIL_COUNT=0
          
          while [ \$(date +%s) -lt \$END_TIME ]; do
            for domain in \$DOMAINS; do
              if nslookup \$domain >/dev/null 2>&1; then
                QUERY_COUNT=\$((QUERY_COUNT + 1))
              else
                FAIL_COUNT=\$((FAIL_COUNT + 1))
              fi
              
              # Sleep to maintain QPS rate
              sleep \$(awk "BEGIN {print 1/$QPS}")
            done
          done
          
          echo "Test completed. Queries: \$QUERY_COUNT, Failures: \$FAIL_COUNT"
        resources:
          requests:
            cpu: "10m"
            memory: "32Mi"
          limits:
            cpu: "50m"
            memory: "64Mi"
EOF

    echo -e "${GREEN}Load test job '$job_name' created${NC}"
    echo ""
    
    # Start monitoring if requested
    if [ "$ENABLE_MONITOR" = true ]; then
        echo -e "${BLUE}Starting monitoring in background...${NC}"
        ./04_monitor_realtime.sh &
        MONITOR_PID=$!
        echo "Monitor PID: $MONITOR_PID"
    fi
    
    # Monitor job progress
    echo -e "${BLUE}Monitoring load test progress...${NC}"
    
    START_TIME=$(date +%s)
    while true; do
        # Get job status
        SUCCEEDED=$(kubectl get job $job_name -n $NAMESPACE -o jsonpath='{.status.succeeded}' 2>/dev/null || echo 0)
        ACTIVE=$(kubectl get job $job_name -n $NAMESPACE -o jsonpath='{.status.active}' 2>/dev/null || echo 0)
        FAILED=$(kubectl get job $job_name -n $NAMESPACE -o jsonpath='{.status.failed}' 2>/dev/null || echo 0)
        
        # Calculate elapsed time
        ELAPSED=$(($(date +%s) - START_TIME))
        REMAINING=$((DURATION - ELAPSED))
        
        # Get DNS metrics
        DNS_PODS=$(kubectl get pods -n kube-system -l k8s-app=kube-dns --no-headers 2>/dev/null | wc -l || echo 0)
        DNS_CPU=$(kubectl top pods -n kube-system -l k8s-app=kube-dns --no-headers 2>/dev/null | \
            awk '{gsub(/m/,"",$2); sum+=$2; count++} END {if (count>0) print int(sum/count/10); else print 0}' || echo 0)
        
        # Check HPA status
        HPA_CURRENT=$(kubectl get hpa -n kube-system kube-dns-autoscaler -o jsonpath='{.status.currentReplicas}' 2>/dev/null || echo "N/A")
        HPA_DESIRED=$(kubectl get hpa -n kube-system kube-dns-autoscaler -o jsonpath='{.status.desiredReplicas}' 2>/dev/null || echo "N/A")
        
        # Display status
        printf "\r${YELLOW}[%3d/%3ds]${NC} Active: %d, Completed: %d, Failed: %d | DNS Pods: %d, CPU: %d%% | HPA: %s/%s replicas" \
            "$ELAPSED" "$DURATION" "$ACTIVE" "$SUCCEEDED" "$FAILED" "$DNS_PODS" "$DNS_CPU" "$HPA_CURRENT" "$HPA_DESIRED"
        
        # Check if job is complete or time is up
        # Ensure variables are numeric
        [[ "${SUCCEEDED:-0}" =~ ^[0-9]+$ ]] || SUCCEEDED=0
        [[ "$ELAPSED" =~ ^[0-9]+$ ]] || ELAPSED=0
        if [ "$SUCCEEDED" -eq "$THREADS" ] || [ "$ELAPSED" -ge "$DURATION" ]; then
            echo ""
            break
        fi
        
        # Check for failures
        [[ "${FAILED:-0}" =~ ^[0-9]+$ ]] || FAILED=0
        if [ "$FAILED" -gt 0 ]; then
            echo ""
            echo -e "${RED}Warning: $FAILED pods failed${NC}"
        fi
        
        sleep 5
    done
    
    # Final results
    echo ""
    echo -e "${GREEN}Load test completed!${NC}"
    echo ""
    
    # Get final metrics
    echo -e "${BLUE}Final DNS Metrics:${NC}"
    kubectl top pods -n kube-system -l k8s-app=kube-dns --no-headers 2>/dev/null || echo "Metrics not available"
    
    echo ""
    echo -e "${BLUE}HPA Status:${NC}"
    kubectl get hpa -n kube-system kube-dns-autoscaler 2>/dev/null || echo "HPA not found"
    
    echo ""
    echo -e "${BLUE}DNS Pod Count History:${NC}"
    kubectl get events -n kube-system --field-selector involvedObject.kind=HorizontalPodAutoscaler,involvedObject.name=kube-dns-autoscaler --sort-by='.lastTimestamp' | tail -5
    
    # Cleanup
    echo ""
    echo -e "${YELLOW}Cleaning up...${NC}"
    kubectl delete job $job_name -n $NAMESPACE
    
    # Stop monitor if running
    if [ "$ENABLE_MONITOR" = true ] && [ -n "${MONITOR_PID:-}" ]; then
        echo "Stopping monitor (PID: $MONITOR_PID)..."
        kill $MONITOR_PID 2>/dev/null || true
    fi
    
    echo -e "${GREEN}Done!${NC}"
}

# Main execution
echo -e "${BLUE}=== DNS Load Testing Tool ===${NC}"
echo "Target cluster: $CURRENT_CONTEXT"
echo ""

# Check if kube-dns HPA exists
if kubectl get hpa -n kube-system kube-dns-autoscaler &>/dev/null; then
    echo -e "${GREEN}✓ HPA for kube-dns found${NC}"
    kubectl get hpa -n kube-system kube-dns-autoscaler
else
    echo -e "${YELLOW}⚠ HPA for kube-dns not found. Creating DNS load anyway...${NC}"
fi

echo ""

# Run the load test
create_load_test