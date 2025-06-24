#!/bin/bash

# Simple cluster breakdown of restart counts
# Generates a quick summary of pods with high restarts organized by cluster

OUTPUT_FILE="cluster_restart_summary.txt"

# List of clusters
CLUSTERS=(
    "quotecenter-yin"
    "gateway-yin"
    "cl-cen-client-gateways"
    "cl-cen-icp-services"
    "cl-cen-acl-services"
    "cl-cen-event-processors"
    "pr-quotecenter-us-cen1-gke-1"
)

# Initialize output
echo "Cluster Restart Summary Report" > $OUTPUT_FILE
echo "Generated: $(date)" >> $OUTPUT_FILE
echo "==============================" >> $OUTPUT_FILE
echo "" >> $OUTPUT_FILE

# Function to analyze cluster
check_cluster() {
    local cluster=$1
    
    echo "Checking $cluster..."
    
    # Get credentials
    if ! gcloud container clusters get-credentials $cluster --region us-central1 2>/dev/null; then
        gcloud container clusters get-credentials $cluster --zone us-central1-a 2>/dev/null || {
            echo "ERROR: Cannot connect to $cluster" >> $OUTPUT_FILE
            echo "" >> $OUTPUT_FILE
            return
        }
    fi
    
    echo "CLUSTER: $cluster" >> $OUTPUT_FILE
    echo "----------------------------------------" >> $OUTPUT_FILE
    
    # Get pods with restart counts > 50
    echo "Pods with >50 restarts:" >> $OUTPUT_FILE
    
    kubectl get pods --all-namespaces -o json 2>/dev/null | jq -r '
        .items[] | 
        select(.status.containerStatuses != null) |
        .metadata.namespace as $ns |
        .metadata.name as $name |
        (.status.containerStatuses | map(.restartCount) | add) as $restarts |
        select($restarts > 50) |
        "\($restarts)\t\($ns)/\($name)"
    ' | sort -nr | head -20 > /tmp/cluster_pods.tmp
    
    if [ -s /tmp/cluster_pods.tmp ]; then
        # Show top 10 pods
        head -10 /tmp/cluster_pods.tmp | while IFS=$'\t' read -r restarts pod; do
            printf "  %-10s %s\n" "$restarts" "$pod" >> $OUTPUT_FILE
        done
        
        # Statistics
        total_pods=$(wc -l < /tmp/cluster_pods.tmp)
        total_restarts=$(awk '{sum+=$1} END {print sum}' /tmp/cluster_pods.tmp)
        echo "" >> $OUTPUT_FILE
        echo "Statistics:" >> $OUTPUT_FILE
        echo "  Total pods with >50 restarts: $total_pods" >> $OUTPUT_FILE
        echo "  Total restart count: $total_restarts" >> $OUTPUT_FILE
        
        # Top namespaces
        echo "" >> $OUTPUT_FILE
        echo "Top namespaces by restart count:" >> $OUTPUT_FILE
        awk -F'[/\t]' '{ns[$2]+=$1; count[$2]++} END {for (n in ns) print ns[n], count[n], n}' /tmp/cluster_pods.tmp | 
            sort -nr | head -5 | 
            while read restarts count ns; do
                printf "  %-10s %s (%d pods)\n" "$restarts" "$ns" "$count" >> $OUTPUT_FILE
            done
    else
        echo "  No pods with >50 restarts found" >> $OUTPUT_FILE
    fi
    
    echo "" >> $OUTPUT_FILE
    echo "" >> $OUTPUT_FILE
    
    rm -f /tmp/cluster_pods.tmp
}

# Main execution
echo "Analyzing restart counts across clusters..."
echo ""

for cluster in "${CLUSTERS[@]}"; do
    check_cluster "$cluster"
done

# Generate overall summary
echo "OVERALL SUMMARY" >> $OUTPUT_FILE
echo "===============" >> $OUTPUT_FILE

# Count clusters with issues
clusters_with_issues=$(grep -c "Total pods with >50 restarts:" $OUTPUT_FILE | grep -v ": 0$" | wc -l)
echo "Clusters analyzed: ${#CLUSTERS[@]}" >> $OUTPUT_FILE
echo "Clusters with high restart pods: $clusters_with_issues" >> $OUTPUT_FILE

echo ""
echo "Report saved to: $OUTPUT_FILE"
echo ""

# Show quick summary on console
echo "Quick Summary:"
echo "--------------"
grep -E "^CLUSTER:|Total restart count:" $OUTPUT_FILE | paste - - | column -t