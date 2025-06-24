#!/bin/bash
# 02_backup_configs.sh - Backup all configurations before changes
# Critical for rollback capability

set -euo pipefail

BACKUP_DIR="config_backups/$(date +%Y%m%d_%H%M%S)"

echo "=== Backing Up Current Configurations ==="
echo "Backup directory: $BACKUP_DIR"
mkdir -p "$BACKUP_DIR"

# 1. Backup DNS deployment
echo "Backing up kube-dns deployment..."
kubectl get deployment kube-dns -n kube-system -o yaml > "$BACKUP_DIR/kube-dns-deployment.yaml"
kubectl get deployment kube-dns -n kube-system -o json > "$BACKUP_DIR/kube-dns-deployment.json"

# 2. Backup ConfigMaps for affected services
echo "Backing up ConfigMaps..."

# Special Order Cost Service
for cm in $(kubectl get cm -n vendor-production -o name | grep -i special-order); do
  echo "  Backing up $cm"
  kubectl get $cm -n vendor-production -o yaml > "$BACKUP_DIR/vendor-$(basename $cm).yaml"
done

# Pricing Service
for cm in $(kubectl get cm -n pricing-production -o name | grep -i pricing); do
  echo "  Backing up $cm"
  kubectl get $cm -n pricing-production -o yaml > "$BACKUP_DIR/pricing-$(basename $cm).yaml"
done

# Dead Letter Projector
for cm in $(kubectl get cm -n vendor-production -o name | grep -i dead-letter); do
  echo "  Backing up $cm"
  kubectl get $cm -n vendor-production -o yaml > "$BACKUP_DIR/vendor-$(basename $cm).yaml"
done

# 3. Backup Deployments
echo "Backing up deployments..."
kubectl get deployment special-order-cost-svc -n vendor-production -o yaml > "$BACKUP_DIR/special-order-cost-svc-deployment.yaml" 2>/dev/null || echo "  Special order cost deployment not found"
kubectl get deployment pro-mro-pricing-svc -n pricing-production -o yaml > "$BACKUP_DIR/pro-mro-pricing-svc-deployment.yaml" 2>/dev/null || echo "  Pricing deployment not found"
kubectl get deployment dead-letter-projector -n vendor-production -o yaml > "$BACKUP_DIR/dead-letter-projector-deployment.yaml" 2>/dev/null || echo "  Dead letter deployment not found"

# 4. Backup HPA if exists
echo "Backing up autoscaling configurations..."
kubectl get hpa -n kube-system -o yaml > "$BACKUP_DIR/kube-system-hpa-all.yaml" 2>/dev/null || echo "  No HPA found in kube-system"

# 5. Create restore script
cat > "$BACKUP_DIR/restore_all.sh" <<'EOF'
#!/bin/bash
# Auto-generated restore script
# Usage: ./restore_all.sh

echo "=== Restoring All Configurations ==="
SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"

# Restore order matters - ConfigMaps first, then Deployments
echo "Restoring ConfigMaps..."
for file in $SCRIPT_DIR/*configmap*.yaml; do
  [ -f "$file" ] && kubectl apply -f "$file"
done

echo "Restoring DNS deployment..."
kubectl apply -f "$SCRIPT_DIR/kube-dns-deployment.yaml"

echo "Restoring service deployments..."
for file in $SCRIPT_DIR/*deployment.yaml; do
  [ -f "$file" ] && [ "$file" != "$SCRIPT_DIR/kube-dns-deployment.yaml" ] && kubectl apply -f "$file"
done

echo "Restarting affected pods..."
kubectl rollout restart deployment special-order-cost-svc -n vendor-production
kubectl rollout restart deployment pro-mro-pricing-svc -n pricing-production
kubectl rollout restart deployment dead-letter-projector -n vendor-production

echo "Restore complete!"
EOF
chmod +x "$BACKUP_DIR/restore_all.sh"

# 6. Create backup inventory
cat > "$BACKUP_DIR/backup_inventory.txt" <<EOF
Backup Inventory
================
Date: $(date)
Cluster: quotecenter-yin

Files Backed Up:
$(ls -1 "$BACKUP_DIR" | grep -v inventory | wc -l) total files

DNS Infrastructure:
- kube-dns-deployment.yaml
- kube-dns-deployment.json

Service Configurations:
$(ls -1 "$BACKUP_DIR" | grep configmap || echo "No ConfigMaps found")

Deployments:
$(ls -1 "$BACKUP_DIR" | grep deployment.yaml | grep -v kube-dns || echo "No service deployments found")

Restore Script:
- restore_all.sh (executable)

To restore everything:
  cd $BACKUP_DIR
  ./restore_all.sh
EOF

echo
echo "=== Backup Complete ==="
echo "Backup location: $BACKUP_DIR"
echo "Files backed up: $(ls -1 "$BACKUP_DIR" | wc -l)"
echo
echo "To restore in case of issues:"
echo "  cd $BACKUP_DIR"
echo "  ./restore_all.sh"