#!/bin/bash
# 07_verify_hpa.sh - Verify HPA configuration for kube-dns

set -euo pipefail

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

echo -e "${BLUE}=== Verifying kube-dns HPA Configuration ===${NC}"
echo ""

# Check current context
CONTEXT=$(kubectl config current-context)
echo "Current context: $CONTEXT"
echo ""

# Check for HPA
echo -e "${BLUE}Checking for HPA...${NC}"
if kubectl get hpa -n kube-system kube-dns 2>/dev/null; then
    echo -e "${GREEN}✓ Found kube-dns HPA${NC}"
elif kubectl get hpa -n kube-system kube-dns-autoscaler 2>/dev/null; then
    echo -e "${GREEN}✓ Found kube-dns-autoscaler HPA${NC}"
else
    echo -e "${RED}✗ No HPA found for kube-dns${NC}"
    echo ""
    echo "Checking all HPAs in kube-system namespace:"
    kubectl get hpa -n kube-system
    echo ""
    echo -e "${YELLOW}The HPA may not be applied yet from your PR.${NC}"
fi

# Check DNS deployment configuration
echo ""
echo -e "${BLUE}Checking kube-dns deployment...${NC}"
kubectl get deployment -n kube-system kube-dns -o yaml | grep -A5 -B5 "replicas:" | head -20

# Check for any autoscaling annotations
echo ""
echo -e "${BLUE}Checking for autoscaling annotations...${NC}"
kubectl get deployment -n kube-system kube-dns -o jsonpath='{.metadata.annotations}' | jq . 2>/dev/null || echo "No annotations found"

# Check resource requests/limits
echo ""
echo -e "${BLUE}Checking kube-dns resource configuration...${NC}"
kubectl get deployment -n kube-system kube-dns -o jsonpath='{.spec.template.spec.containers[*].resources}' | jq . 2>/dev/null || \
    kubectl get deployment -n kube-system kube-dns -o yaml | grep -A10 "resources:"

# Suggest HPA configuration if missing
if ! kubectl get hpa -n kube-system | grep -q "kube-dns"; then
    echo ""
    echo -e "${YELLOW}Suggested HPA configuration:${NC}"
    cat <<EOF
---
apiVersion: autoscaling/v2
kind: HorizontalPodAutoscaler
metadata:
  name: kube-dns
  namespace: kube-system
spec:
  scaleTargetRef:
    apiVersion: apps/v1
    kind: Deployment
    name: kube-dns
  minReplicas: 4
  maxReplicas: 20
  metrics:
  - type: Resource
    resource:
      name: cpu
      target:
        type: Utilization
        averageUtilization: 50
  - type: Resource
    resource:
      name: memory
      target:
        type: Utilization
        averageUtilization: 80
  behavior:
    scaleDown:
      stabilizationWindowSeconds: 300
      policies:
      - type: Percent
        value: 10
        periodSeconds: 60
    scaleUp:
      stabilizationWindowSeconds: 60
      policies:
      - type: Percent
        value: 100
        periodSeconds: 60
      - type: Pods
        value: 4
        periodSeconds: 60
EOF
fi