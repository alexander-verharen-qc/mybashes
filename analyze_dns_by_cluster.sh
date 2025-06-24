#!/bin/bash

# DNS Issue Analysis Script - Cluster Breakdown
# This script analyzes DNS-related issues across GKE clusters with detailed per-cluster reporting

# Output files
SUMMARY_FILE="dns_cluster_summary.txt"
DETAIL_DIR="cluster_dns_reports"
COMBINED_REPORT="dns_analysis_combined.txt"

# Create output directory
mkdir -p "$DETAIL_DIR"

# List of clusters to analyze
CLUSTERS=(
    "quotecenter-yin"
    "gateway-yin"
    "cl-cen-client-gateways"
    "cl-cen-icp-services"
    "cl-cen-acl-services"
    "cl-cen-event-processors"
    "pr-quotecenter-us-cen1-gke-1"
)

# DNS-related error patterns to search for
DNS_PATTERNS=(
    "no such host"
    "cannot resolve"
    "name resolution"
    "dns lookup"
    "getaddrinfo"
    "temporary failure in name resolution"
    "NoHostAvailableException"
    "UnknownHostException"
)

# Initialize summary
echo "DNS Issue Analysis - Cluster Summary" > $SUMMARY_FILE
echo "Generated on: $(date)" >> $SUMMARY_FILE
echo "========================================" >> $SUMMARY_FILE
echo "" >> $SUMMARY_FILE

# Function to check DNS-related errors in pod logs
check_dns_errors() {
    local namespace=$1
    local pod=$2
    local cluster=$3
    local output_file=$4
    
    echo "      Checking logs for DNS errors..." >> $output_file
    
    # Try to get recent logs
    if kubectl logs $pod -n $namespace --tail=100 --since=1h 2>/dev/null | grep -iE "($(IFS='|'; echo "${DNS_PATTERNS[*]}"))" > /tmp/dns_errors.tmp; then
        echo "      DNS-related errors found:" >> $output_file
        cat /tmp/dns_errors.tmp | head -5 | sed 's/^/        /' >> $output_file
        error_count=$(wc -l < /tmp/dns_errors.tmp)
        echo "        ... ($error_count total DNS errors in last hour)" >> $output_file
    else
        echo "        No recent DNS errors detected in logs" >> $output_file
    fi
    rm -f /tmp/dns_errors.tmp
}

# Function to analyze a single cluster
analyze_cluster() {
    local cluster=$1
    local cluster_file="$DETAIL_DIR/${cluster}_dns_report.txt"
    
    echo "Analyzing cluster: $cluster"
    
    # Initialize cluster report
    echo "DNS Analysis Report for Cluster: $cluster" > $cluster_file
    echo "Generated on: $(date)" >> $cluster_file
    echo "========================================" >> $cluster_file
    echo "" >> $cluster_file
    
    # Get cluster credentials
    echo "Getting credentials for $cluster..."
    if ! gcloud container clusters get-credentials $cluster --region us-central1 2>/dev/null; then
        if ! gcloud container clusters get-credentials $cluster --zone us-central1-a 2>/dev/null; then
            echo "ERROR: Unable to get credentials for cluster $cluster" >> $cluster_file
            echo "$cluster: ERROR - Unable to connect" >> $SUMMARY_FILE
            return
        fi
    fi
    
    # Get cluster info
    echo "Cluster Information:" >> $cluster_file
    echo "-------------------" >> $cluster_file
    kubectl get nodes | wc -l | awk '{print "Total Nodes: " $1-1}' >> $cluster_file
    echo "" >> $cluster_file
    
    # Check CoreDNS status
    echo "CoreDNS Status:" >> $cluster_file
    echo "---------------" >> $cluster_file
    kubectl get pods -n kube-system -l k8s-app=kube-dns -o wide >> $cluster_file 2>&1
    echo "" >> $cluster_file
    
    # Get pods with high restart counts
    echo "Pods with High Restart Counts (>10):" >> $cluster_file
    echo "------------------------------------" >> $cluster_file
    
    # Temporary file for this cluster
    TEMP_FILE="/tmp/${cluster}_pods.tmp"
    
    # Get all pods with restart information
    kubectl get pods --all-namespaces -o json | jq -r '
        .items[] | 
        select(.status.containerStatuses != null) |
        .metadata.namespace as $ns |
        .metadata.name as $name |
        .spec.nodeName as $node |
        .status.phase as $phase |
        (.status.containerStatuses | map(.restartCount) | add) as $restarts |
        "\($ns) \($name) \($phase) \($restarts) \($node)"
    ' | awk '$4 > 10' | sort -k4 -nr > $TEMP_FILE
    
    # Process results by namespace
    if [ -s $TEMP_FILE ]; then
        # Get statistics
        total_affected_pods=$(wc -l < $TEMP_FILE)
        total_restarts=$(awk '{sum+=$4} END {print sum}' $TEMP_FILE)
        unique_namespaces=$(awk '{print $1}' $TEMP_FILE | sort -u | wc -l)
        
        # Write cluster summary
        echo "$cluster:" >> $SUMMARY_FILE
        echo "  Status: ISSUES DETECTED" >> $SUMMARY_FILE
        echo "  Affected Pods: $total_affected_pods" >> $SUMMARY_FILE
        echo "  Total Restarts: $total_restarts" >> $SUMMARY_FILE
        echo "  Affected Namespaces: $unique_namespaces" >> $SUMMARY_FILE
        
        # Group by namespace in detail report
        current_ns=""
        while IFS=' ' read -r ns pod phase restarts node; do
            if [ "$ns" != "$current_ns" ]; then
                current_ns=$ns
                echo "" >> $cluster_file
                echo "Namespace: $ns" >> $cluster_file
                echo "  Pods with issues:" >> $cluster_file
            fi
            
            # Extract service name from pod
            service=$(echo "$pod" | sed -E 's/-[0-9a-f]{8,10}-[a-z0-9]{5}$//' | sed -E 's/-[0-9]+$//')
            
            echo "    Pod: $pod" >> $cluster_file
            echo "      Service: $service" >> $cluster_file
            echo "      Status: $phase" >> $cluster_file
            echo "      Restarts: $restarts" >> $cluster_file
            echo "      Node: $node" >> $cluster_file
            
            # Check for DNS errors in logs (only for top 5 pods per namespace to save time)
            pod_count=$(grep -c "^$ns " $TEMP_FILE)
            if [ $pod_count -le 5 ]; then
                check_dns_errors "$ns" "$pod" "$cluster" "$cluster_file"
            fi
            
            echo "" >> $cluster_file
        done < $TEMP_FILE
        
        # Add namespace summaries
        echo "" >> $cluster_file
        echo "Summary by Namespace:" >> $cluster_file
        echo "--------------------" >> $cluster_file
        awk '{ns[$1]++; restarts[$1]+=$4} END {for (n in ns) printf "  %s: %d pods, %d total restarts\n", n, ns[n], restarts[n]}' $TEMP_FILE | sort -k4 -nr >> $cluster_file
        
        # Top services with issues
        echo "" >> $cluster_file
        echo "Top 10 Services by Restart Count:" >> $cluster_file
        echo "---------------------------------" >> $cluster_file
        while IFS=' ' read -r ns pod phase restarts node; do
            service=$(echo "$pod" | sed -E 's/-[0-9a-f]{8,10}-[a-z0-9]{5}$//' | sed -E 's/-[0-9]+$//')
            echo "$service $restarts"
        done < $TEMP_FILE | awk '{svc[$1]+=$2} END {for (s in svc) print svc[s], s}' | sort -nr | head -10 | awk '{print "  " $2 ": " $1 " restarts"}' >> $cluster_file
        
    else
        echo "$cluster: OK - No pods with high restart counts" >> $SUMMARY_FILE
        echo "No pods with restart counts > 10 found." >> $cluster_file
    fi
    
    # Check for pods in CrashLoopBackOff
    echo "" >> $cluster_file
    echo "Pods in CrashLoopBackOff State:" >> $cluster_file
    echo "-------------------------------" >> $cluster_file
    kubectl get pods --all-namespaces --field-selector=status.phase!=Running,status.phase!=Succeeded -o wide | grep -E "CrashLoopBackOff|Error" >> $cluster_file 2>&1 || echo "None found." >> $cluster_file
    
    # DNS resolution test from within cluster
    echo "" >> $cluster_file
    echo "DNS Resolution Test:" >> $cluster_file
    echo "-------------------" >> $cluster_file
    echo "Testing resolution of internal services..." >> $cluster_file
    
    # Test DNS resolution for common internal domains
    kubectl run dns-test-$RANDOM --image=busybox:1.28 --rm -it --restart=Never --command -- nslookup kubernetes.default 2>&1 | grep -A2 "Name:" >> $cluster_file || echo "DNS test failed" >> $cluster_file
    
    echo "" >> $cluster_file
    echo "========================================" >> $cluster_file
    
    # Cleanup
    rm -f $TEMP_FILE
    
    # Add separator in summary
    echo "" >> $SUMMARY_FILE
}

# Function to create combined report
create_combined_report() {
    echo "Creating combined report..."
    
    echo "DNS Issue Analysis - Combined Report" > $COMBINED_REPORT
    echo "Generated on: $(date)" >> $COMBINED_REPORT
    echo "========================================" >> $COMBINED_REPORT
    echo "" >> $COMBINED_REPORT
    
    # Add summary
    echo "EXECUTIVE SUMMARY" >> $COMBINED_REPORT
    echo "-----------------" >> $COMBINED_REPORT
    cat $SUMMARY_FILE | tail -n +5 >> $COMBINED_REPORT
    
    echo "" >> $COMBINED_REPORT
    echo "DETAILED CLUSTER REPORTS" >> $COMBINED_REPORT
    echo "========================" >> $COMBINED_REPORT
    
    # Add each cluster report
    for cluster in "${CLUSTERS[@]}"; do
        cluster_file="$DETAIL_DIR/${cluster}_dns_report.txt"
        if [ -f "$cluster_file" ]; then
            echo "" >> $COMBINED_REPORT
            echo "" >> $COMBINED_REPORT
            cat "$cluster_file" >> $COMBINED_REPORT
        fi
    done
    
    # Generate cross-cluster analysis
    echo "" >> $COMBINED_REPORT
    echo "" >> $COMBINED_REPORT
    echo "CROSS-CLUSTER ANALYSIS" >> $COMBINED_REPORT
    echo "======================" >> $COMBINED_REPORT
    echo "" >> $COMBINED_REPORT
    
    # Find common problematic services across clusters
    echo "Services with Issues Across Multiple Clusters:" >> $COMBINED_REPORT
    echo "---------------------------------------------" >> $COMBINED_REPORT
    
    # Extract service names and their restart counts from all reports
    for report in $DETAIL_DIR/*_dns_report.txt; do
        cluster=$(basename "$report" | sed 's/_dns_report.txt//')
        grep -E "Service:|Restarts:" "$report" | paste - - | awk -v cluster="$cluster" '{gsub(/[[:space:]]+Service:[[:space:]]+/, "", $1); gsub(/[[:space:]]+Restarts:[[:space:]]+/, "", $3); print $1, $3, cluster}'
    done | awk '
    {
        services[$1][$3] = $2
        total[$1] += $2
        clusters[$1]++
    }
    END {
        for (svc in services) {
            if (clusters[svc] > 1) {
                print "  " svc " (found in " clusters[svc] " clusters, total restarts: " total[svc] ")"
                for (cluster in services[svc]) {
                    print "    - " cluster ": " services[svc][cluster] " restarts"
                }
                print ""
            }
        }
    }' >> $COMBINED_REPORT
    
    echo "" >> $COMBINED_REPORT
    echo "Analysis complete." >> $COMBINED_REPORT
}

# Main execution
echo "Starting DNS issue analysis across GKE clusters..."
echo "This may take several minutes..."
echo ""

# Analyze each cluster
for cluster in "${CLUSTERS[@]}"; do
    analyze_cluster "$cluster"
    echo "Completed analysis for $cluster"
    echo ""
done

# Create combined report
create_combined_report

echo ""
echo "Analysis complete!"
echo "Files generated:"
echo "  - Summary: $SUMMARY_FILE"
echo "  - Detailed reports: $DETAIL_DIR/"
echo "  - Combined report: $COMBINED_REPORT"
echo ""
echo "Key files to review:"
echo "  1. $SUMMARY_FILE - Quick overview of all clusters"
echo "  2. $COMBINED_REPORT - Complete analysis with cross-cluster insights"