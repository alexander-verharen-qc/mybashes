#!/bin/bash
# 05_emergency_rollback.sh - Emergency rollback procedure
# Use this if things go wrong during implementation

set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

echo -e "${RED}=== EMERGENCY ROLLBACK INITIATED ===${NC}"
echo "Time: $(date)"
echo "Reason: $*"
echo

# Function to find latest backup
find_latest_backup() {
    local latest=$(ls -dt config_backups/*/ 2>/dev/null | head -1)
    if [ -z "$latest" ]; then
        echo "ERROR: No backup directory found!"
        exit 1
    fi
    echo "$latest"
}

# 1. Stop any ongoing operations
echo -e "${YELLOW}Step 1: Stopping ongoing operations...${NC}"
# Kill any running scale operations
pkill -f "kubectl scale" || true
pkill -f "kubectl rollout" || true

# 2. Restore DNS to original state
echo -e "${YELLOW}Step 2: Restoring DNS to 2 replicas...${NC}"
kubectl scale deployment kube-dns -n kube-system --replicas=2
echo "Waiting for DNS rollback..."
kubectl rollout status deployment kube-dns -n kube-system --timeout=5m || true

# 3. Find and restore from backup
echo -e "${YELLOW}Step 3: Restoring configurations from backup...${NC}"
BACKUP_DIR=$(find_latest_backup)
echo "Using backup: $BACKUP_DIR"

if [ -f "$BACKUP_DIR/restore_all.sh" ]; then
    echo "Executing restore script..."
    bash "$BACKUP_DIR/restore_all.sh"
else
    echo "Manual restore from backup..."
    # Restore ConfigMaps
    for file in "$BACKUP_DIR"/*configmap*.yaml; do
        [ -f "$file" ] && kubectl apply -f "$file" && echo "  Restored: $(basename $file)"
    done
    
    # Restore Deployments
    for file in "$BACKUP_DIR"/*deployment.yaml; do
        [ -f "$file" ] && kubectl apply -f "$file" && echo "  Restored: $(basename $file)"
    done
fi

# 4. Force restart affected services
echo -e "${YELLOW}Step 4: Restarting affected services...${NC}"
for ns in vendor-production pricing-production; do
    echo "Restarting pods in $ns..."
    kubectl delete pods -n "$ns" -l app=special-order-cost-svc --grace-period=30 2>/dev/null || true
    kubectl delete pods -n "$ns" -l app=pro-mro-pricing-svc --grace-period=30 2>/dev/null || true
    kubectl delete pods -n "$ns" -l app=dead-letter-projector --grace-period=30 2>/dev/null || true
done

# 5. Clear any stuck jobs
echo -e "${YELLOW}Step 5: Cleaning up stuck resources...${NC}"
kubectl delete jobs -A --field-selector status.successful=0 2>/dev/null || echo "  No failed jobs to clean"

# 6. Verify rollback
echo -e "${YELLOW}Step 6: Verifying rollback status...${NC}"
sleep 10

# Check DNS
DNS_PODS=$(kubectl get pods -n kube-system -l k8s-app=kube-dns --no-headers | wc -l)
DNS_RUNNING=$(kubectl get pods -n kube-system -l k8s-app=kube-dns --no-headers | grep -c Running || echo 0)
echo "DNS Status: $DNS_RUNNING/$DNS_PODS running"

# Check critical services
FAILING_PODS=$(kubectl get pods -A --no-headers | grep -E "CrashLoopBackOff|Error|ImagePullBackOff" | wc -l)
echo "Failing pods: $FAILING_PODS"

# 7. Generate rollback report
REPORT_FILE="rollback_report_$(date +%Y%m%d_%H%M%S).txt"
cat > "$REPORT_FILE" <<EOF
Emergency Rollback Report
========================
Date: $(date)
Reason: $*

Actions Taken:
1. Stopped ongoing operations
2. Scaled DNS back to 2 replicas
3. Restored configurations from: $BACKUP_DIR
4. Restarted affected services
5. Cleaned up stuck resources

Current Status:
- DNS Pods: $DNS_RUNNING/$DNS_PODS running
- Failing Pods: $FAILING_PODS
- Backup Used: $BACKUP_DIR

Post-Rollback Checklist:
[ ] Verify DNS is stable (2 pods running)
[ ] Check critical services are starting
[ ] Monitor for 30 minutes
[ ] Review logs to understand failure
[ ] Update runbook with lessons learned

Critical Services to Monitor:
- special-order-cost-svc
- pro-mro-pricing-svc
- dead-letter-projector

Commands for verification:
kubectl get pods -n kube-system -l k8s-app=kube-dns
kubectl get pods -A | grep -E "special-order|pricing|dead-letter"
kubectl top pods -n kube-system -l k8s-app=kube-dns
EOF

echo
echo -e "${GREEN}=== ROLLBACK COMPLETE ===${NC}"
echo "Report saved to: $REPORT_FILE"
echo
echo -e "${YELLOW}IMPORTANT: Monitor the cluster for the next 30 minutes${NC}"
echo "Run monitoring script: ./04_monitor_realtime.sh"
echo
echo "If issues persist:"
echo "1. Check the rollback report: $REPORT_FILE"
echo "2. Review pod logs for errors"
echo "3. Consider manual intervention for specific services"