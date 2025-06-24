#!/bin/bash
# 01_baseline_metrics.sh - Collect baseline metrics before changes
# Run this BEFORE making any changes to establish baseline

set -euo pipefail

TIMESTAMP=$(date +%Y%m%d_%H%M%S)
BASELINE_DIR="pre_change_baseline_$TIMESTAMP"

echo "=== Collecting Baseline Metrics for quotecenter-yin ==="
echo "Timestamp: $TIMESTAMP"
echo "Output directory: $BASELINE_DIR"

mkdir -p "$BASELINE_DIR"

# 1. Current DNS pod status and metrics
echo "Collecting DNS pod metrics..."
kubectl get pods -n kube-system -l k8s-app=kube-dns -o wide > "$BASELINE_DIR/dns_pods_status.txt"
kubectl top pods -n kube-system -l k8s-app=kube-dns > "$BASELINE_DIR/dns_cpu_baseline.txt" 2>&1 || echo "Metrics server unavailable"

# 2. High restart count summary
echo "Analyzing pod restart counts..."
kubectl get pods -A --no-headers | awk '$4 > 10' > "$BASELINE_DIR/high_restart_pods_full.txt"
kubectl get pods -A --no-headers | awk '$4 > 10' | wc -l > "$BASELINE_DIR/high_restart_count.txt"

# 3. Service health by namespace
echo "Checking service health..."
for ns in vendor-production pricing-production catalog-production data-production; do
  echo "Namespace: $ns"
  kubectl get pods -n $ns -o wide > "$BASELINE_DIR/${ns}_pods.txt" 2>&1 || echo "Namespace $ns not found"
  
  # Count failing pods
  kubectl get pods -n $ns --no-headers | grep -E "CrashLoopBackOff|Error|ImagePullBackOff" | wc -l > "$BASELINE_DIR/${ns}_failing_count.txt" 2>&1 || echo "0"
done

# 4. DNS query latency test
echo "Testing DNS resolution performance..."
cat > "$BASELINE_DIR/dns_test.sh" <<'EOF'
#!/bin/bash
for i in {1..10}; do
  start=$(date +%s.%N)
  kubectl run dns-test-$i --image=gcr.io/google-containers/dnsutils:latest --rm -it --restart=Never -- \
    nslookup kubernetes.default.svc.cluster.local 2>&1 | grep -E "Address|time"
  end=$(date +%s.%N)
  echo "Query $i took: $(echo "$end - $start" | bc) seconds"
  sleep 1
done
EOF
chmod +x "$BASELINE_DIR/dns_test.sh"

# 5. Current Cassandra-related errors
echo "Checking for Cassandra DNS errors..."
for pod in $(kubectl get pods -n vendor-production -o name | grep special-order); do
  echo "Checking $pod..."
  kubectl logs -n vendor-production $pod --tail=100 2>&1 | grep -i "no host" > "$BASELINE_DIR/cassandra_errors_$(basename $pod).txt" || echo "No recent errors"
done

# 6. Create summary report
cat > "$BASELINE_DIR/baseline_summary.txt" <<EOF
Baseline Metrics Summary
========================
Timestamp: $TIMESTAMP
Cluster: quotecenter-yin

DNS Infrastructure:
- DNS Pods: $(kubectl get pods -n kube-system -l k8s-app=kube-dns --no-headers | wc -l)
- High Restart Pods: $(cat "$BASELINE_DIR/high_restart_count.txt")

Failed Pods by Namespace:
- vendor-production: $(cat "$BASELINE_DIR/vendor-production_failing_count.txt" 2>/dev/null || echo "0")
- pricing-production: $(cat "$BASELINE_DIR/pricing-production_failing_count.txt" 2>/dev/null || echo "0")
- catalog-production: $(cat "$BASELINE_DIR/catalog-production_failing_count.txt" 2>/dev/null || echo "0")

Known Issues:
- special-order-cost-svc: Cassandra DNS failures (pr-cen-cass-supply-*)
- pro-mro-pricing-svc: Cassandra DNS failures (pr-cen-cass-pricing-*)
- dead-letter-projector: High restart count (2125)

Next Steps:
1. Review this baseline data
2. Proceed with DNS scaling during off-peak hours
3. Monitor changes against these baselines
EOF

echo
echo "=== Baseline Collection Complete ==="
echo "Results saved to: $BASELINE_DIR/"
echo
echo "Key metrics:"
cat "$BASELINE_DIR/baseline_summary.txt"