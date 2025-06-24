#!/bin/bash
# 06_dns_stress_test.sh - Aggressive DNS stress testing for HPA validation
# Uses dnsperf/resperf for realistic DNS load generation

set -euo pipefail

# Configuration
DEFAULT_DURATION=300
DEFAULT_CLIENTS=50
DEFAULT_QPS_PER_CLIENT=50

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

Aggressive DNS Stress Testing Tool for kube-dns HPA validation

OPTIONS:
    -d, --duration <seconds>    Test duration (default: $DEFAULT_DURATION)
    -c, --clients <number>      Number of client pods (default: $DEFAULT_CLIENTS)
    -q, --qps <number>         Target QPS per client (default: $DEFAULT_QPS_PER_CLIENT)
    -n, --namespace <name>      Namespace for test pods (default: default)
    -m, --monitor              Enable real-time monitoring
    -h, --help                 Display this help

EXAMPLES:
    # Standard load test
    $0

    # High-intensity test with monitoring
    $0 -c 100 -q 100 -m

    # Quick test
    $0 -d 60 -c 20 -q 25

EOF
    exit 1
}

# Parse arguments
DURATION=$DEFAULT_DURATION
CLIENTS=$DEFAULT_CLIENTS
QPS_PER_CLIENT=$DEFAULT_QPS_PER_CLIENT
NAMESPACE="default"
ENABLE_MONITOR=false

while [[ $# -gt 0 ]]; do
    case $1 in
        -d|--duration) DURATION="$2"; shift 2 ;;
        -c|--clients) CLIENTS="$2"; shift 2 ;;
        -q|--qps) QPS_PER_CLIENT="$2"; shift 2 ;;
        -n|--namespace) NAMESPACE="$2"; shift 2 ;;
        -m|--monitor) ENABLE_MONITOR=true; shift ;;
        -h|--help) usage ;;
        *) echo -e "${RED}Unknown option: $1${NC}"; usage ;;
    esac
done

# Validate cluster
CURRENT_CONTEXT=$(kubectl config current-context)
echo -e "${BLUE}=== DNS Stress Test Tool ===${NC}"
echo "Target cluster: $CURRENT_CONTEXT"

if [[ ! "$CURRENT_CONTEXT" =~ "np-quotecenter" ]]; then
    echo -e "${YELLOW}Warning: Not on np-quotecenter cluster${NC}"
    echo -n "Continue? (y/N): "
    read -r response
    [[ ! "$response" =~ ^[Yy]$ ]] && exit 1
fi

# Check HPA
echo ""
if kubectl get hpa -n kube-system kube-dns-autoscaler &>/dev/null; then
    echo -e "${GREEN}✓ HPA found for kube-dns${NC}"
    kubectl get hpa -n kube-system kube-dns-autoscaler
else
    echo -e "${YELLOW}⚠ No HPA found for kube-dns${NC}"
fi

# Get initial metrics
echo ""
echo -e "${BLUE}Initial DNS metrics:${NC}"
INITIAL_PODS=$(kubectl get pods -n kube-system -l k8s-app=kube-dns --no-headers | wc -l)
echo "DNS Pods: $INITIAL_PODS"
kubectl top pods -n kube-system -l k8s-app=kube-dns 2>/dev/null || echo "Metrics not available yet"

# Create ConfigMap with domains to test
echo ""
echo -e "${BLUE}Creating test configuration...${NC}"

cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: ConfigMap
metadata:
  name: dns-test-domains
  namespace: $NAMESPACE
data:
  domains.txt: |
    kubernetes.default.svc.cluster.local
    kube-dns.kube-system.svc.cluster.local
    metrics-server.kube-system.svc.cluster.local
    special-order-cost-svc.vendor-production.svc.cluster.local
    pro-mro-pricing-svc.pricing-production.svc.cluster.local
    dead-letter-projector.vendor-production.svc.cluster.local
    cassandra.cassandra.svc.cluster.local
    cassandra-0.cassandra.cassandra.svc.cluster.local
    cassandra-1.cassandra.cassandra.svc.cluster.local
    cassandra-2.cassandra.cassandra.svc.cluster.local
    google.com
    cloudflare.com
    nonexistent-$(date +%s).invalid
EOF

# Create stress test deployment
DEPLOYMENT_NAME="dns-stress-test-$(date +%s)"
TOTAL_QPS=$((CLIENTS * QPS_PER_CLIENT))

echo -e "${BLUE}Deploying stress test...${NC}"
echo "Configuration:"
echo "  Duration: ${DURATION}s"
echo "  Client Pods: $CLIENTS"
echo "  QPS per client: $QPS_PER_CLIENT"
echo "  Total target QPS: $TOTAL_QPS"
echo ""

cat <<EOF | kubectl apply -f -
apiVersion: apps/v1
kind: Deployment
metadata:
  name: $DEPLOYMENT_NAME
  namespace: $NAMESPACE
  labels:
    app: dns-stress-test
spec:
  replicas: $CLIENTS
  selector:
    matchLabels:
      app: dns-stress-test
      test: $DEPLOYMENT_NAME
  template:
    metadata:
      labels:
        app: dns-stress-test
        test: $DEPLOYMENT_NAME
    spec:
      containers:
      - name: dns-stress
        image: tutum/dnsutils:latest
        command: ["/bin/sh", "-c"]
        args:
        - |
          echo "Starting DNS stress test on \$(hostname)"
          
          # Create query file from ConfigMap
          cp /config/domains.txt /tmp/queries.txt
          
          # Generate more queries by adding random prefixes
          for i in \$(seq 1 50); do
            sed "s/^/test-\$i-/" /config/domains.txt >> /tmp/queries.txt
          done
          
          END_TIME=\$(($(date +%s) + $DURATION))
          TOTAL_QUERIES=0
          TOTAL_FAILURES=0
          
          while [ \$(date +%s) -lt \$END_TIME ]; do
            # Burst mode: rapid queries
            for i in \$(seq 1 10); do
              while read domain; do
                if dig @kube-dns.kube-system.svc.cluster.local \$domain +short +time=1 +tries=1 >/dev/null 2>&1; then
                  TOTAL_QUERIES=\$((TOTAL_QUERIES + 1))
                else
                  TOTAL_FAILURES=\$((TOTAL_FAILURES + 1))
                fi
              done < /tmp/queries.txt &
            done
            
            # Wait for batch to complete
            wait
            
            # Small delay to control rate
            sleep 0.1
          done
          
          echo "Test complete. Queries: \$TOTAL_QUERIES, Failures: \$TOTAL_FAILURES"
          sleep infinity  # Keep pod running for logs
        volumeMounts:
        - name: config
          mountPath: /config
        resources:
          requests:
            cpu: "50m"
            memory: "64Mi"
          limits:
            cpu: "200m"
            memory: "128Mi"
      volumes:
      - name: config
        configMap:
          name: dns-test-domains
      terminationGracePeriodSeconds: 5
EOF

# Start monitoring if requested
if [ "$ENABLE_MONITOR" = true ]; then
    echo -e "${BLUE}Starting monitor...${NC}"
    ./04_monitor_realtime.sh &
    MONITOR_PID=$!
fi

# Wait for pods to start
echo -e "${BLUE}Waiting for stress test pods to start...${NC}"
kubectl wait --for=condition=ready pod -l test=$DEPLOYMENT_NAME -n $NAMESPACE --timeout=60s 2>/dev/null || true

# Monitor progress
echo -e "${BLUE}Stress test running...${NC}"
START_TIME=$(date +%s)
MAX_DNS_PODS=0
MAX_CPU=0

while true; do
    ELAPSED=$(($(date +%s) - START_TIME))
    
    # Get metrics
    ACTIVE_PODS=$(kubectl get pods -n $NAMESPACE -l test=$DEPLOYMENT_NAME --field-selector=status.phase=Running --no-headers | wc -l)
    DNS_PODS=$(kubectl get pods -n kube-system -l k8s-app=kube-dns --no-headers | wc -l)
    DNS_CPU=$(kubectl top pods -n kube-system -l k8s-app=kube-dns --no-headers 2>/dev/null | \
        awk '{gsub(/m/,"",$2); sum+=$2; count++} END {if (count>0) print int(sum/count/10); else print 0}' || echo 0)
    
    # Track maximums
    # Ensure variables are numeric before comparison
    [[ "$DNS_PODS" =~ ^[0-9]+$ ]] && [[ "$MAX_DNS_PODS" =~ ^[0-9]+$ ]] && [ $DNS_PODS -gt $MAX_DNS_PODS ] && MAX_DNS_PODS=$DNS_PODS
    [[ "$DNS_CPU" =~ ^[0-9]+$ ]] && [[ "$MAX_CPU" =~ ^[0-9]+$ ]] && [ $DNS_CPU -gt $MAX_CPU ] && MAX_CPU=$DNS_CPU
    
    # HPA status
    HPA_CURRENT=$(kubectl get hpa -n kube-system kube-dns-autoscaler -o jsonpath='{.status.currentReplicas}' 2>/dev/null || echo "N/A")
    HPA_TARGET=$(kubectl get hpa -n kube-system kube-dns-autoscaler -o jsonpath='{.spec.targetCPUUtilizationPercentage}' 2>/dev/null || echo "N/A")
    
    # Display progress
    printf "\r${YELLOW}[%3d/%3ds]${NC} Stress Pods: %d | DNS Pods: %d (max: %d) | CPU: %d%% (max: %d%%) | HPA: %s (target: %s%%)" \
        "$ELAPSED" "$DURATION" "$ACTIVE_PODS" "$DNS_PODS" "$MAX_DNS_PODS" "$DNS_CPU" "$MAX_CPU" "$HPA_CURRENT" "$HPA_TARGET"
    
    # Check completion
    [[ "$ELAPSED" =~ ^[0-9]+$ ]] && [ $ELAPSED -ge $DURATION ] && break
    
    sleep 5
done

echo ""
echo ""
echo -e "${GREEN}Stress test completed!${NC}"
echo ""

# Final results
echo -e "${BLUE}=== Test Results ===${NC}"
echo "Duration: ${DURATION}s"
echo "Client Pods: $CLIENTS"
echo "Target QPS: $TOTAL_QPS"
echo ""
echo "DNS Scaling:"
echo "  Initial pods: $INITIAL_PODS"
echo "  Maximum pods: $MAX_DNS_PODS"
echo "  Maximum CPU: $MAX_CPU%"
echo ""

# Show final metrics
echo -e "${BLUE}Final DNS pod metrics:${NC}"
kubectl top pods -n kube-system -l k8s-app=kube-dns

echo ""
echo -e "${BLUE}HPA events during test:${NC}"
kubectl get events -n kube-system --field-selector involvedObject.kind=HorizontalPodAutoscaler,involvedObject.name=kube-dns-autoscaler --sort-by='.lastTimestamp' | tail -10

# Sample pod logs
echo ""
echo -e "${BLUE}Sample stress test results:${NC}"
SAMPLE_POD=$(kubectl get pods -n $NAMESPACE -l test=$DEPLOYMENT_NAME --no-headers | head -1 | awk '{print $1}')
kubectl logs $SAMPLE_POD -n $NAMESPACE 2>/dev/null | grep -E "Queries:|Test complete" | tail -5

# Cleanup
echo ""
echo -e "${YELLOW}Cleaning up...${NC}"
kubectl delete deployment $DEPLOYMENT_NAME -n $NAMESPACE
kubectl delete configmap dns-test-domains -n $NAMESPACE 2>/dev/null || true

# Stop monitor
if [ "$ENABLE_MONITOR" = true ] && [ -n "${MONITOR_PID:-}" ]; then
    kill $MONITOR_PID 2>/dev/null || true
fi

echo -e "${GREEN}Done!${NC}"