#!/bin/bash
# 03_scale_dns_safely.sh - Safely scale DNS with monitoring
# Run during OFF-PEAK hours (8pm-6am PST)

set -euo pipefail

# Configuration
TARGET_REPLICAS=5
STEP_DELAY=300  # 5 minutes between scaling steps
CPU_THRESHOLD=80  # CPU percentage threshold

echo "=== DNS Scaling Script for quotecenter-yin ==="
echo "Current time: $(date)"
echo "Target replicas: $TARGET_REPLICAS"
echo

# Function to check DNS health
check_dns_health() {
    local unhealthy=0
    
    # Check if all pods are running
    local running=$(kubectl get pods -n kube-system -l k8s-app=kube-dns --no-headers | grep -c Running || echo 0)
    local total=$(kubectl get pods -n kube-system -l k8s-app=kube-dns --no-headers | wc -l)
    
    if [ "$running" -ne "$total" ]; then
        echo "WARNING: Not all DNS pods are running ($running/$total)"
        unhealthy=1
    fi
    
    # Check CPU usage if metrics available
    if kubectl top pods -n kube-system &>/dev/null; then
        local high_cpu=$(kubectl top pods -n kube-system -l k8s-app=kube-dns --no-headers | \
            awk '{gsub(/m/,"",$2); if($2 > '$CPU_THRESHOLD'*10) print $1}' | wc -l)
        if [ "$high_cpu" -gt 0 ]; then
            echo "WARNING: $high_cpu DNS pods have CPU > ${CPU_THRESHOLD}%"
            unhealthy=1
        fi
    fi
    
    return $unhealthy
}

# Function to scale DNS gradually
scale_dns_step() {
    local new_replicas=$1
    echo "Scaling kube-dns to $new_replicas replicas..."
    
    kubectl scale deployment kube-dns -n kube-system --replicas="$new_replicas"
    
    # Wait for rollout
    echo "Waiting for rollout to complete..."
    kubectl rollout status deployment kube-dns -n kube-system --timeout=5m
    
    # Show current state
    echo "Current DNS pods:"
    kubectl get pods -n kube-system -l k8s-app=kube-dns -o wide
    
    # Check metrics if available
    if kubectl top pods -n kube-system &>/dev/null; then
        echo -e "\nCPU usage:"
        kubectl top pods -n kube-system -l k8s-app=kube-dns
    fi
}

# Main scaling logic
echo "=== Starting DNS Scaling Process ==="

# Get current replica count
CURRENT_REPLICAS=$(kubectl get deployment kube-dns -n kube-system -o jsonpath='{.spec.replicas}')
echo "Current replicas: $CURRENT_REPLICAS"

if [ "$CURRENT_REPLICAS" -ge "$TARGET_REPLICAS" ]; then
    echo "Already at or above target replicas. No scaling needed."
    exit 0
fi

# Pre-flight check
echo -e "\nPre-flight health check..."
if ! check_dns_health; then
    echo "ERROR: DNS is not healthy. Fix issues before scaling."
    exit 1
fi

# Scale incrementally
for (( replicas = CURRENT_REPLICAS + 1; replicas <= TARGET_REPLICAS; replicas++ )); do
    echo -e "\n=== Scaling Step: $CURRENT_REPLICAS → $replicas ==="
    
    scale_dns_step "$replicas"
    
    echo -e "\nWaiting $STEP_DELAY seconds before next step..."
    echo "Monitoring DNS health during wait period..."
    
    # Monitor during wait period
    for (( i = 0; i < STEP_DELAY; i += 30 )); do
        sleep 30
        echo -n "."
        if ! check_dns_health; then
            echo -e "\nERROR: DNS health degraded after scaling to $replicas replicas"
            echo "Rolling back to $((replicas-1)) replicas..."
            kubectl scale deployment kube-dns -n kube-system --replicas=$((replicas-1))
            exit 1
        fi
    done
    echo " OK"
    
    CURRENT_REPLICAS=$replicas
done

# Final validation
echo -e "\n=== Scaling Complete ==="
echo "Final DNS pod status:"
kubectl get pods -n kube-system -l k8s-app=kube-dns -o wide

if kubectl top pods -n kube-system &>/dev/null; then
    echo -e "\nFinal CPU usage:"
    kubectl top pods -n kube-system -l k8s-app=kube-dns
fi

# Update resource limits if needed
echo -e "\n=== Updating DNS Resource Limits ==="
cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: ConfigMap
metadata:
  name: kube-dns-autoscale
  namespace: kube-system
data:
  linear: |
    {
      "coresPerReplica": 256,
      "nodesPerReplica": 16,
      "preventSinglePointFailure": true,
      "min": 5,
      "max": 10
    }
EOF

echo -e "\n=== Creating DNS Monitoring Alert ==="
cat > dns_scale_complete_$(date +%Y%m%d_%H%M%S).txt <<EOF
DNS Scaling Complete
====================
Date: $(date)
Cluster: quotecenter-yin
Initial Replicas: $CURRENT_REPLICAS
Final Replicas: $(kubectl get deployment kube-dns -n kube-system -o jsonpath='{.spec.replicas}')

Next Steps:
1. Monitor DNS performance during next peak hours (9am-3pm PST)
2. Check pod restart rates
3. Verify DNS query latency
4. Proceed with Cassandra configuration fixes if stable

Monitoring commands:
- kubectl top pods -n kube-system -l k8s-app=kube-dns
- kubectl get pods -A | grep -E "CrashLoopBackOff|Error" | wc -l
EOF

echo
echo "✓ DNS scaling complete!"
echo "✓ Monitor performance during next peak hours"
echo "✓ Check dns_scale_complete_*.txt for summary"