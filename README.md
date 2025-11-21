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
- **function-claude**: Analyzes metrics from XR status every minute (demo frequency)
- Makes scaling decisions using **Claude Haiku 4.5** (85%+ cost reduction vs Sonnet)
- Only scales resources with `scale: me` label
- Rate-limited to prevent scaling thrash
- **Requires**: function-claude v0.4.0+ for reliable markdown handling

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

### Cost Expectations (Haiku Model)

**AI inference costs at 1-minute schedule (demo)**:
- ~$9.52/day per database
- ~$285/month per database
- ~$3,470/year per database

**Production schedules** (cost scales with frequency):
- 5-minute: ~$695/year per database
- 10-minute: ~$347/year per database
- 30-minute: ~$116/year per database

*Note: Costs include AI analysis only, not AWS infrastructure*

### Production Results
- ✅ **End-to-end pipeline**: All components synced and ready
- ✅ **Real-time decisions**: ~2-5 second analysis latency
- ✅ **Cost-efficient AI**: ~$0.02-0.04 per scaling decision
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

## Performance Testing (perftest)

### How to Run Performance Tests

This repository includes automated scripts to validate the intelligent scaling system and trigger AI-driven scaling decisions.

#### Automated Load Test with Monitoring

Use `perf-scale-demo.sh` for a complete end-to-end scaling demonstration:

```bash
# Run with defaults (rds-metrics-database-ai-mysql in database-team namespace)
./perf-scale-demo.sh

# Custom SQLInstance name
./perf-scale-demo.sh my-database

# Custom SQLInstance and namespace
./perf-scale-demo.sh my-database default
```

**What it does**:
- Automatically extracts connection details from the SQLInstance's connection secret
- Launches 30 concurrent MySQL processes with intensive CPU load (BENCHMARK operations)
- Monitors CPU utilization, instance class, and scaling decisions every 20 seconds
- Automatically stops when scaling is detected or after 5 minutes
- Cleans up all background processes on completion

**Expected timeline**:
1. 30-60 seconds: CPU reaches 50%+ utilization
2. 1-2 minutes: CloudWatch metrics update
3. Next CronOperation run: Claude analyzes metrics and triggers scaling
4. 5-10 minutes: Instance class upgrade completes

#### Continuous Monitoring

Use `simple-demo-scaling-monitor.sh` to watch scaling decisions in real-time:

```bash
# Monitor with defaults (45-second refresh interval)
./simple-demo-scaling-monitor.sh

# Custom SQLInstance name
./simple-demo-scaling-monitor.sh my-database

# Custom refresh interval (30 seconds)
./simple-demo-scaling-monitor.sh my-database default 30
```

**What it displays**:
- CPU utilization, free memory, and database connections
- Current instance class
- All `intelligent-scaling/*` annotations (last-scaled-decision, last-scaled-at, cooldown-until)
- Refreshes continuously until stopped (Ctrl+C)

#### Expected Behavior
1. **CPU Spike**: Database CPU reaches 60%+ utilization (threshold for demo scaling)
2. **Metrics Collection**: function-rds-metrics captures CloudWatch data in XR status
3. **AI Analysis**: Claude Haiku evaluates metrics against thresholds
4. **Scaling Decision**: Instance class upgraded (e.g., db.t3.micro → db.t3.small → db.t3.medium)
5. **Cooldown Period**: 5-minute rate limit prevents scaling thrash
6. **Performance Recovery**: CPU utilization drops after scaling completes

## Testing

The configuration can be tested using:

- `up composition render --xrd=apis/definition.yaml apis/composition-rds-metrics.yaml examples/mariadb-xr-rds-metrics.yaml --function-credentials=tests/test-credentials.yaml` to render the composition
- `up test run tests/test-sqlinstance/` to run composition tests
- `up test run tests/e2etest-sqlinstance/ --e2e` to run end-to-end tests

## Crossplane v2.0 Operations

This configuration includes **Crossplane Operations** for automated intelligent scaling using both scheduled and reactive patterns. Operations are automatically deployed with `up project run`.

### CronOperation: Scheduled Scaling Analysis
- **Schedule**: Every minute (`* * * * *`) for demo - adjust for production
- **Target**: SQLInstance resources with `scale: me` label
- **Purpose**: Regular scheduled analysis for predictable workloads
- **Rate Limiting**: 5-minute cooldown between scaling actions
- **Recommended production**: 5-10 minute intervals for cost optimization

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