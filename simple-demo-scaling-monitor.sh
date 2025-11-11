#!/bin/bash
# simple-demo-scaling-monitor.sh - Monitor SQLInstance scaling decisions and metrics
#
# Usage:
#   ./simple-demo-scaling-monitor.sh [XR_NAME] [NAMESPACE] [INTERVAL]
#
# Examples:
#   ./simple-demo-scaling-monitor.sh                                    # Uses defaults
#   ./simple-demo-scaling-monitor.sh rds-metrics-database-ai-mysql      # Custom XR name
#   ./simple-demo-scaling-monitor.sh my-db default 30                   # Custom XR, namespace, and 30s interval

# Configuration
XR_NAME="${1:-rds-metrics-database-ai-mysql}"
XR_NAMESPACE="${2:-database-team}"
INTERVAL="${3:-45}"
CONTEXT="upbound"

echo "📊 Monitoring: SQLInstance/${XR_NAME} in namespace ${XR_NAMESPACE}"
echo "⏱️  Refresh interval: ${INTERVAL} seconds"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

while true; do
    echo "╔══════════════════════════════════════════════════════════════════╗"
    echo "║ $(date '+%Y-%m-%d %H:%M:%S')                                            ║"
    echo "╚══════════════════════════════════════════════════════════════════╝"

    # Get performance metrics
    CPU=$(kubectl --context $CONTEXT get sqlinstance -n ${XR_NAMESPACE} ${XR_NAME} \
        -o jsonpath='{.status.performanceMetrics.metrics.CPUUtilization.value}' 2>/dev/null || echo "N/A")
    MEMORY=$(kubectl --context $CONTEXT get sqlinstance -n ${XR_NAMESPACE} ${XR_NAME} \
        -o jsonpath='{.status.performanceMetrics.metrics.FreeableMemory.value}' 2>/dev/null || echo "N/A")
    CONNECTIONS=$(kubectl --context $CONTEXT get sqlinstance -n ${XR_NAMESPACE} ${XR_NAME} \
        -o jsonpath='{.status.performanceMetrics.metrics.DatabaseConnections.value}' 2>/dev/null || echo "N/A")

    # Get instance class
    INSTANCE_CLASS=$(kubectl --context $CONTEXT get sqlinstance -n ${XR_NAMESPACE} ${XR_NAME} \
        -o jsonpath='{.spec.parameters.instanceClass}' 2>/dev/null || echo "N/A")

    echo "📈 Performance Metrics:"
    echo "   CPU:         ${CPU}%"
    echo "   Memory:      ${MEMORY} bytes free"
    echo "   Connections: ${CONNECTIONS}"
    echo "   Instance:    ${INSTANCE_CLASS}"
    echo ""

    # Get scaling annotations
    echo "🤖 Scaling Annotations:"
    kubectl --context $CONTEXT get sqlinstance -n ${XR_NAMESPACE} ${XR_NAME} -o yaml 2>/dev/null | \
        yq '.metadata.annotations | with_entries(select(.key | test("intelligent-scaling"))) // "No intelligent-scaling annotations found"'

    echo ""
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""
    sleep $INTERVAL
done
