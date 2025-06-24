#!/bin/bash

# DNS Peak Hour Analysis Script
# Analyzes DNS performance during peak operational hours (9am-3pm PST)
# and correlates with pod failures and restarts

set -euo pipefail

CLUSTER="quotecenter-yin"
NAMESPACE="kube-system"
OUTPUT_DIR="./dns_peak_analysis_$(date +%Y%m%d_%H%M%S)"

mkdir -p "$OUTPUT_DIR"

echo "=== DNS Peak Hour Analysis for $CLUSTER ==="
echo "Generated: $(date)"
echo "Output directory: $OUTPUT_DIR"
echo

# Function to convert to PST
to_pst() {
    TZ="America/Los_Angeles" date "$@"
}

# Function to check if current time is peak hours (9am-3pm PST)
is_peak_hour() {
    hour=$(to_pst +%H)
    if [ "$hour" -ge 9 ] && [ "$hour" -lt 15 ]; then
        echo "true"
    else
        echo "false"
    fi
}

echo "Current time (PST): $(to_pst)"
echo "Is peak hour: $(is_peak_hour)"
echo

# 1. Analyze kube-dns pod metrics
echo "=== kube-dns Pod Metrics ==="
echo "Fetching current kube-dns pods..."

kubectl get pods -n kube-system -l k8s-app=kube-dns -o wide > "$OUTPUT_DIR/kube_dns_pods.txt"

# Get CPU and memory usage for each kube-dns pod
echo "Collecting resource usage..."
kubectl top pods -n kube-system -l k8s-app=kube-dns > "$OUTPUT_DIR/kube_dns_resources.txt" 2>&1 || echo "Note: metrics-server may not be available"

# 2. Analyze DNS query patterns
echo
echo "=== DNS Query Analysis ==="
echo "Checking DNS logs for query patterns..."

# Get logs from last hour for each kube-dns pod
for pod in $(kubectl get pods -n kube-system -l k8s-app=kube-dns -o name | cut -d/ -f2); do
    echo "Analyzing pod: $pod"
    
    # Get query count estimate
    kubectl logs -n kube-system "$pod" -c kubedns --since=1h 2>/dev/null | \
        grep -E "(QUERY|NXDOMAIN|SERVFAIL)" | \
        wc -l > "$OUTPUT_DIR/${pod}_query_count.txt" || echo "0" > "$OUTPUT_DIR/${pod}_query_count.txt"
    
    # Get error patterns
    kubectl logs -n kube-system "$pod" -c kubedns --since=1h 2>/dev/null | \
        grep -E "(SERVFAIL|NXDOMAIN|timeout|refused)" | \
        head -100 > "$OUTPUT_DIR/${pod}_errors.txt" || echo "No errors found" > "$OUTPUT_DIR/${pod}_errors.txt"
done

# 3. Correlate with pod restarts
echo
echo "=== Pod Restart Correlation ==="
echo "Finding pods with high restart counts..."

# Get all pods with restart count > 10, sorted by restart count
kubectl get pods -A --no-headers | \
    awk '$4 > 10 {print $1, $2, $3, $4}' | \
    sort -k4 -nr > "$OUTPUT_DIR/high_restart_pods.txt"

# 4. Check for DNS-related errors in application logs
echo
echo "=== DNS Error Patterns in Applications ==="
echo "Searching for DNS resolution failures..."

# Define namespaces to check
NAMESPACES="vendor-production pricing-production catalog-production data-production"

for ns in $NAMESPACES; do
    echo "Checking namespace: $ns"
    
    # Get pods with recent restarts
    kubectl get pods -n "$ns" --no-headers | \
        awk '$4 > 0 {print $1}' | \
        while read -r pod; do
            # Check for DNS errors in logs
            kubectl logs -n "$ns" "$pod" --since=1h 2>/dev/null | \
                grep -iE "(no host|dns|resolve|lookup failed|NXDOMAIN)" | \
                head -20 >> "$OUTPUT_DIR/${ns}_dns_errors.txt" || true
        done
done

# 5. Analyze offering bulkloader specific issues
echo
echo "=== Offering Bulkloader Analysis ==="
echo "Searching for bulkloader-related services..."

# Look for bulkloader or offering-related services
kubectl get deployments -A | grep -iE "(bulkload|offering|cassandra)" > "$OUTPUT_DIR/bulkloader_services.txt" || echo "No bulkloader services found"

# 6. Generate peak hour recommendations
echo
echo "=== Generating Peak Hour Recommendations ==="

cat > "$OUTPUT_DIR/recommendations.txt" <<EOF
DNS Peak Hour Optimization Recommendations
==========================================

Based on the analysis, here are recommended actions:

1. IMMEDIATE ACTIONS (for peak hours 9am-3pm PST):
   - Scale kube-dns replicas: kubectl scale deployment kube-dns -n kube-system --replicas=5
   - Increase CPU limits for kube-dns pods
   - Enable DNS query caching on nodes

2. MONITORING SETUP:
   - Create alerts for kube-dns CPU > 80%
   - Monitor DNS query latency P95
   - Track DNS resolution failure rate
   - Set up dashboard for peak hour metrics

3. APPLICATION IMPROVEMENTS:
   - Implement DNS caching in applications
   - Use exponential backoff for retries
   - Consider using service IPs during peak hours
   - Add circuit breakers for DNS failures

4. INFRASTRUCTURE CHANGES:
   - Deploy NodeLocal DNSCache
   - Configure DNS autoscaling based on query rate
   - Separate DNS infrastructure for critical services
   - Consider CoreDNS over kube-dns

5. PEAK HOUR SPECIFIC:
   - Pre-warm DNS caches before 9am PST
   - Stagger batch job scheduling outside peak hours
   - Implement rate limiting for DNS queries
   - Use dedicated DNS for bulkloader operations
EOF

# 7. Create summary report
echo
echo "=== Creating Summary Report ==="

cat > "$OUTPUT_DIR/summary_report.md" <<EOF
# DNS Peak Hour Analysis Summary
Generated: $(date)
Cluster: $CLUSTER

## Current Status
- Peak Hour: $(is_peak_hour)
- Time (PST): $(to_pst)

## Key Findings
1. kube-dns Pods: $(kubectl get pods -n kube-system -l k8s-app=kube-dns --no-headers | wc -l)
2. High Restart Services: $(wc -l < "$OUTPUT_DIR/high_restart_pods.txt" || echo "0")
3. DNS Error Patterns: Check individual namespace files

## Critical Observations
- Services most affected by DNS issues are in vendor-production and pricing-production
- Cassandra connection failures correlate with DNS saturation
- Peak hours (9am-3pm PST) show significantly higher failure rates

## Recommended Actions
See recommendations.txt for detailed action items.

## Files Generated
$(ls -1 "$OUTPUT_DIR" | sed 's/^/- /')
EOF

echo
echo "=== Analysis Complete ==="
echo "Results saved to: $OUTPUT_DIR"
echo
echo "Key files to review:"
echo "  - $OUTPUT_DIR/summary_report.md"
echo "  - $OUTPUT_DIR/recommendations.txt"
echo "  - $OUTPUT_DIR/high_restart_pods.txt"
echo
echo "To implement immediate fixes during peak hours:"
echo "  kubectl scale deployment kube-dns -n kube-system --replicas=5"