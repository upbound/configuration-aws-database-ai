# AWS Database Configuration

This repository contains an Upbound project, tailored for users establishing their initial control plane with [Upbound](https://cloud.upbound.io). This configuration deploys fully managed AWS database instances.

## Overview

The core components of a custom API in [Upbound Project](https://docs.upbound.io/learn/control-plane-project/) include:

- **CompositeResourceDefinition (XRD):** Defines the API's structure.
- **Composition(s):** Configures the Functions Pipeline
- **Embedded Function(s):** Encapsulates the Composition logic and implementation within a self-contained, reusable unit

In this specific configuration, the API contains:

- **an [AWS Database](/apis/definition.yaml) custom resource type (v2 namespaced).**
- **Composition:** Configured in [/apis/composition-rds-metrics.yaml](/apis/composition-rds-metrics.yaml)
- **Embedded Function:** The Composition logic is encapsulated within [embedded function](/functions/sqlinstance/main.k)

## Intelligent RDS Scaling with Crossplane Operations

### Architecture
**Pipeline Flow**: `RDS Instance → CloudWatch Metrics → Status → Operations (Scheduled AI Analysis)`

```
┌─────────────────┐    ┌──────────────────┐
│   RDS Instance  │    │ function-rds-    │
│                 │───▶│    metrics       │───▶ status.performanceMetrics
│ (CloudWatch)    │    │                  │
└─────────────────┘    └──────────────────┘
                                                      │
                                                      ▼
                                            ┌─────────────────────┐
                                            │ CronOperation       │
                                            │ (Every 10 min)      │
                                            │                     │
                                            │ function-claude     │
                                            │ (Claude AI)         │
                                            └─────────────────────┘
                                                      │
                                                      ▼
                                            ┌─────────────────┐
                                            │ Scaling Actions │
                                            │ + Audit Trail   │
                                            └─────────────────┘
```

### Component Integration

**1. Composition Pipeline**
- **function-rds-metrics**: Fetches CloudWatch metrics (CPU, memory, IOPS, connections, storage)
- Writes metrics to `status.performanceMetrics` for Operations consumption
- **function-auto-ready**: Marks composition ready

**2. CronOperation (Scheduled Scaling)**
- **function-claude**: Analyzes metrics from XR status every 10 minutes
- Makes scaling decisions using Claude Sonnet 4.0
- Only scales resources with `scale: me` label
- Rate-limited to prevent scaling thrash

### Key Technical Challenges Solved

**1. Large YAML Handling**
- **Problem**: Claude failed with empty tool parameters for complex observed resources
- **Solution**: Increased `maxTokens` from 1024 → 8192 and refined prompt engineering

**2. Pipeline Context Flow**
- **Problem**: function-claude wasn't receiving metrics from previous pipeline step
- **Solution**: Extended input schema with `contextFields` parameter for generic context access

**3. Resource State Management**
- **Problem**: First reconciliation had empty observed resources
- **Solution**: Fallback logic to use desired resources when observed is empty

**4. Schema Validation**
- **Problem**: Returning full observed state caused resourceRefs uid schema errors
- **Solution**: Prompt engineering to return only clean desired spec excluding system fields

### Decision Making Process

**Input**: Real CloudWatch metrics
```yaml
performanceMetrics:
  metrics:
    CPUUtilization: { value: 1.98, unit: "Percent" }
    DatabaseConnections: { value: 0, unit: "Count" }
    FreeStorageSpace: { value: 2775404544, unit: "Bytes" }
    # ... other metrics
```

**AI Analysis**: Claude evaluates against thresholds
- CPU >80% → scale up instance class
- Memory <20% free → memory-optimized instance  
- IOPS >80% → increase storage/instance
- Connections >80% → larger instance

**Output**: Structured decision with audit trail
```yaml
status:
  claudeDecision:
    reasoning: "CPU utilization at 1.98% is well below 80% threshold..."
    timestamp: "2025-07-29T22:05:18Z"
```

### Production Results
- ✅ **End-to-end pipeline**: All components synced and ready
- ✅ **Real-time decisions**: ~2-5 second analysis latency  
- ✅ **Cost efficiency**: ~$0.06-0.12 per scaling decision
- ✅ **Audit compliance**: Full reasoning captured in XR status
- ✅ **Safety**: Only scales up, prevents accidental downsizing

### Usage
Deploy an intelligent scaling database:
```yaml
apiVersion: aws.platform.upbound.io/v1alpha1
kind: SQLInstance
metadata:
  name: my-intelligent-db
  namespace: default
  labels:
    scale: me  # Enable CronOperation scaling
spec:
  crossplane:
    compositionSelector:
      matchLabels:
        type: rds-metrics
  parameters:
    engine: mariadb
    engineVersion: "10.11"
    storageGB: 20
    region: us-west-2
    networkRef:
      id: my-network
    passwordSecretRef:
      name: my-db-password
      key: password
    # ... other parameters
```

### Prerequisites
1. **Claude API Secret**: Store Anthropic API key in control plane
   ```bash
   kubectl create secret generic claude \
     --from-literal=ANTHROPIC_API_KEY=your-api-key \
     -n crossplane-system
   ```

2. **AWS Credentials**: Ensure CloudWatch metrics access for RDS monitoring

**Current Status**: **Experimental** - Successfully proven concept with real infrastructure, ready for production validation and monitoring.

## Load Testing and Benchmarking

### Database Stress Testing for AI Scaling Validation

To validate the intelligent scaling system, you can stress test the RDS instance to trigger high CPU utilization and observe AI-driven scaling decisions:

#### MySQL/MariaDB Stress Test
```bash
# Trigger high CPU load with multiple concurrent MD5 hash computations
for i in {1..8}; do
    mysql \
      --host=your-rds-endpoint.region.rds.amazonaws.com \
      --user=masteruser \
      --password=your-password \
      --default-auth=mysql_native_password \
      --execute="SELECT BENCHMARK(1000000000, MD5('trigger_scaling_$i'));" &
done
```

#### PostgreSQL Stress Test
```bash
# Alternative for PostgreSQL instances
for i in {1..8}; do
    psql "postgresql://masteruser:password@your-rds-endpoint.region.rds.amazonaws.com/upbound" \
      -c "SELECT md5(generate_series(1,10000000)::text);" &
done
```

#### Expected Behavior
1. **CPU Spike**: Database CPU should reach 80%+ utilization within 1-2 minutes
2. **Metrics Collection**: function-rds-metrics captures high CPU in context
3. **AI Analysis**: Claude detects threshold breach and recommends scaling
4. **Infrastructure Change**: Instance class upgraded (e.g., db.t3.micro → db.t3.small)
5. **Performance Recovery**: CPU utilization drops after scaling completes

#### Monitoring Scaling Events
```bash
# Watch Claude's scaling decisions
kubectl get sqlinstance your-db-name -n default -o jsonpath='{.status.claudeDecision}' | jq .

# Check current instance class via Kubernetes
kubectl get instance.rds.aws.m.upbound.io -n default -l crossplane.io/composite=your-db-name -o jsonpath='{.items[0].spec.forProvider.instanceClass}'

# Monitor instance class changes with watch
kubectl get instance.rds.aws.m.upbound.io -n default -l crossplane.io/composite=your-db-name -o custom-columns=NAME:.metadata.name,CLASS:.spec.forProvider.instanceClass,STATUS:.status.conditions[-1].type --watch

# Check performance metrics from XR status
kubectl get sqlinstance your-db-name -n default -o jsonpath='{.status.performanceMetrics}' | jq .

# Monitor CronOperation executions
kubectl get operation -n crossplane-system --watch

# Alternative: Monitor AWS console for instance class changes
aws rds describe-db-instances --db-instance-identifier your-db-name --query 'DBInstances[0].DBInstanceClass'
```

#### Cleanup
```bash
# Stop all background processes
pkill -f "mysql.*BENCHMARK"
# or for PostgreSQL
pkill -f "psql.*generate_series"
```

## Testing

The configuration can be tested using:

- `up composition render --xrd=apis/definition.yaml apis/composition-rds-metrics.yaml examples/mariadb-xr-rds-metrics.yaml --function-credentials=tests/test-credentials.yaml` to render the composition
- `up test run tests/test-sqlinstance/` to run composition tests
- `up test run tests/e2etest-sqlinstance/ --e2e` to run end-to-end tests

## Crossplane v2.0 Operations

This configuration includes **Crossplane Operations** for automated intelligent scaling using both scheduled and reactive patterns. Operations are automatically deployed with `up project run`.

### CronOperation: Scheduled Scaling Analysis
- **Schedule**: Every 10 minutes (`*/10 * * * *`) for proactive monitoring
- **Target**: SQLInstance resources with `scale: me` label
- **Purpose**: Regular scheduled analysis for predictable workloads
- **Rate Limiting**: 5-minute cooldown between scaling actions

### Operation Features
- **AI-Powered Decision Making**: Uses `upbound-function-claude` for intelligent scaling decisions
- **Conservative Thresholds**: CPU >85%, Memory <15%, Connections >85%
- **Instance Progression**: `db.t3.micro → db.t3.small → db.t3.medium → db.t3.large`
- **Rate Limiting**: Annotations-based cooldown to prevent excessive scaling
- **Audit Trail**: Full reasoning captured in resource annotations

### Quick Start with Operations
1. **Setup Claude API Secret**:
   ```bash
   kubectl create secret generic claude \
     --from-literal=ANTHROPIC_API_KEY=your-api-key \
     -n crossplane-system
   ```

2. **Deploy Configuration and Operations**:
   ```bash
   up project run  # Automatically includes operations/
   ```

3. **Deploy Example with Scaling Labels**:
   ```bash
   # Network dependency
   kubectl apply -f examples/network-rds-metrics.yaml
   
   # Database with scaling enabled
   kubectl apply -f examples/mariadb-xr-rds-metrics.yaml
   ```

4. **Monitor Operations**:
   ```bash
   # Check operation status
   kubectl get cronoperation,watchoperation -n crossplane-system
   
   # Monitor operation executions
   kubectl get operation -n crossplane-system --watch
   ```

### Example Resources for Operations Testing
The configuration includes dedicated examples for operations testing:
- `examples/network-rds-metrics.yaml`: Network setup for RDS metrics testing
- `examples/mariadb-xr-rds-metrics.yaml`: MariaDB SQLInstance with `scale: me` label for operation targeting
- `examples/postgres-xr-rds-metrics.yaml`: PostgreSQL SQLInstance for testing

## Deployment

- Execute `up project run` (automatically includes operations)
- Alternatively, install the Configuration from the [Upbound Marketplace](https://marketplace.upbound.io/configurations/upbound/configuration-aws-database)
- Check [examples](/examples/) for example XR(Composite Resource)

## Next steps

This repository serves as a foundational step. To enhance the configuration, consider:

1. create new API definitions in this same repo
2. editing the existing API definition to your needs

To learn more about how to build APIs for your managed control planes in Upbound, read the guide on [Upbound's docs](https://docs.upbound.io/).