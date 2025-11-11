#!/bin/bash
# Demo-optimized load test for fast autoscaling trigger
#
# Usage:
#   ./perf-scale-demo.sh [XR_NAME] [NAMESPACE]
#
# Examples:
#   ./perf-scale-demo.sh                                    # Uses defaults
#   ./perf-scale-demo.sh rds-metrics-database-ai-mysql      # Custom XR name
#   ./perf-scale-demo.sh my-db default                      # Custom XR and namespace

# Configuration
XR_NAME="${1:-rds-metrics-database-ai-mysql}"
XR_NAMESPACE="${2:-database-team}"
SECRET_NAME="${XR_NAME}-connection"

echo "🎯 Target: SQLInstance/${XR_NAME} in namespace ${XR_NAMESPACE}"
echo "🔍 Reading connection details from secret ${SECRET_NAME}..."

# Extract connection details from Kubernetes secret
DB_ENDPOINT=$(kubectl get secret -n ${XR_NAMESPACE} ${SECRET_NAME} -o jsonpath='{.data.host}' | base64 -d)
DB_USER=$(kubectl get secret -n ${XR_NAMESPACE} ${SECRET_NAME} -o jsonpath='{.data.username}' | base64 -d)
DB_PASS=$(kubectl get secret -n ${XR_NAMESPACE} ${SECRET_NAME} -o jsonpath='{.data.password}' | base64 -d)
DB_PORT=$(kubectl get secret -n ${XR_NAMESPACE} ${SECRET_NAME} -o jsonpath='{.data.port}' | base64 -d)

if [[ -z "$DB_ENDPOINT" ]] || [[ -z "$DB_USER" ]] || [[ -z "$DB_PASS" ]]; then
    echo "❌ Failed to retrieve connection details from secret ${SECRET_NAME}"
    echo "   Make sure the SQLInstance and secret exist in namespace ${XR_NAMESPACE}"
    exit 1
fi

echo "✅ Connected to: ${DB_ENDPOINT}:${DB_PORT}"
echo ""
echo "🚀 Starting DEMO load test (optimized for speed)..."

# Maximum intensity load - 20 processes with high benchmark values
for i in {1..20}; do
    mysql --host=$DB_ENDPOINT --user=$DB_USER --password=$DB_PASS \
          --default-auth=mysql_native_password \
          --execute="SELECT BENCHMARK(3000000000, MD5('demo_intensive_$i'));" &
done

# Additional CPU-intensive operations
for i in {1..10}; do
    mysql --host=$DB_ENDPOINT --user=$DB_USER --password=$DB_PASS \
          --execute="
            SELECT BENCHMARK(1000000000, SHA2(CONCAT('demo_', RAND()), 256));
            SELECT BENCHMARK(1000000000, MD5(CONCAT(CONNECTION_ID(), '_$i')));
          " &
done

echo ""
echo "⏱️  Load test running... Expected timeline:"
echo "   - 30-60 seconds: CPU should hit 50%+"
echo "   - 1-2 minutes: CloudWatch metrics update"
echo "   - Next CronOperation run (every 2 minutes): Claude analysis and scaling decision"
echo "   - 5-10 minutes: Instance scaling completion"

# Real-time monitoring
echo ""
echo "⏱️  Monitoring for scaling events (checking every 20 seconds for up to 5 minutes)..."
for i in {1..15}; do
    echo ""
    echo "=== Demo Check $i ($(date +%H:%M:%S)) ==="

    # Current metrics
    CPU=$(kubectl get sqlinstance -n ${XR_NAMESPACE} ${XR_NAME} -o jsonpath='{.status.performanceMetrics.metrics.CPUUtilization.value}' 2>/dev/null || echo "collecting...")
    echo "🔥 CPU: ${CPU}% (threshold: 60% for scale-up)"

    # Instance class
    CLASS=$(kubectl get instance.rds.aws.m.upbound.io -n ${XR_NAMESPACE} -l crossplane.io/composite=${XR_NAME} -o jsonpath='{.items[0].spec.forProvider.instanceClass}' 2>/dev/null || echo "unknown")
    echo "💾 Instance: $CLASS"

    # Scaling decision
    LAST_DECISION=$(kubectl get sqlinstance -n ${XR_NAMESPACE} ${XR_NAME} -o jsonpath='{.metadata.annotations.intelligent-scaling/last-scaled-decision}' 2>/dev/null || echo "no decision yet...")
    echo "🤖 Decision: ${LAST_DECISION:0:100}..."

    # Check if scaling happened
    if [[ "$CLASS" != "db.t3.micro" ]]; then
        echo ""
        echo "🎉 SCALING SUCCESSFUL! Instance upgraded to $CLASS"
        break
    fi

    sleep 20
done

echo ""
echo "🛑 Stopping load test..."
pkill -f "mysql.*BENCHMARK"
pkill -f "mysql.*SHA2"

echo ""
echo "✅ Demo complete!"
echo ""
echo "📊 Final status check:"
kubectl get sqlinstance -n ${XR_NAMESPACE} ${XR_NAME} -o jsonpath='{"CPU: "}{.status.performanceMetrics.metrics.CPUUtilization.value}{"%\nInstance: "}{.spec.parameters.instanceClass}{"\nDecision: "}{.metadata.annotations.intelligent-scaling/last-scaled-decision}{"\n"}'
