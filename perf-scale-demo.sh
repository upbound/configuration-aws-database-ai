  #!/bin/bash
  # Demo-optimized load test for fast autoscaling trigger

  DB_ENDPOINT="rds-metrics-database-ai-scale.cxal1lomznba.us-west-2.rds.amazonaws.com"
  DB_USER="masteruser"
  DB_PASS="YzZiCjT6vitMxClxBmE7OH8IScb"
  XR_NAME="rds-metrics-database-ai-scale"

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

  echo "⏱️  Load test running... Expected timeline:"
  echo "   - 30-60 seconds: CPU should hit 50%+"
  echo "   - 1-2 minutes: CloudWatch metrics update"
  echo "   - 2-3 minutes: Claude analysis and scaling decision"
  echo "   - 5-10 minutes: Instance scaling completion"

  # Real-time monitoring
  for i in {1..15}; do
      echo ""
      echo "=== Demo Check $i ($(date +%H:%M:%S)) ==="

      # Current metrics
      CPU=$(kubectl get xsqlinstance $XR_NAME -o jsonpath='{.status.performanceMetrics.metrics.CPUUtilization.value}'
  2>/dev/null || echo "collecting...")
      echo "🔥 CPU: ${CPU}% (threshold: 50%)"

      # Instance class
      CLASS=$(kubectl get instance.rds -l crossplane.io/composite=$XR_NAME -o
  jsonpath='{.items[0].spec.forProvider.instanceClass}' 2>/dev/null || echo "unknown")
      echo "💾 Instance: $CLASS"

      # Claude decision
      REASONING=$(kubectl get xsqlinstance $XR_NAME -o jsonpath='{.status.claudeDecision.reasoning}' 2>/dev/null || echo "analyzing...")
      echo "🤖 Claude: ${REASONING:0:80}..."

      # Check if scaling happened
      if [[ "$CLASS" != "db.t3.micro" ]]; then
          echo "🎉 SCALING SUCCESSFUL! Instance upgraded to $CLASS"
          break
      fi

      sleep 20
  done

  echo ""
  echo "🛑 Stopping load test..."
  pkill -f "mysql.*BENCHMARK"
  pkill -f "mysql.*SHA2"

  echo "✅ Demo complete!"
