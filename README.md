# AWS Database Configuration

This repository contains an Upbound project, tailored for users establishing their initial control plane with [Upbound](https://cloud.upbound.io). This configuration deploys fully managed AWS database instances.

## Overview

The core components of a custom API in [Upbound Project](https://docs.upbound.io/learn/control-plane-project/) include:

- **CompositeResourceDefinition (XRD):** Defines the API's structure.
- **Composition(s):** Configures the Functions Pipeline
- **Embedded Function(s):** Encapsulates the Composition logic and implementation within a self-contained, reusable unit

In this specific configuration, the API contains:

- **an [AWS Database](/apis/definition.yaml) custom resource type.**
- **Composition:** Configured in [/apis/composition.yaml](/apis/composition.yaml)
- **Embedded Function:** The Composition logic is encapsulated within [embedded function](/functions/xsqlinstance/main.k)

## Intelligent RDS Scaling Experiment

### Architecture
**Pipeline Flow**: `RDS Instance → CloudWatch Metrics → AI Analysis → Scaling Decisions`

```
┌─────────────────┐    ┌──────────────────┐    ┌─────────────────┐
│   RDS Instance  │    │ function-rds-    │    │ function-claude │
│                 │───▶│    metrics       │───▶│                 │
│ (CloudWatch)    │    │                  │    │ (Claude AI)     │
└─────────────────┘    └──────────────────┘    └─────────────────┘
                              │                        │
                              ▼                        ▼
                    ┌──────────────────┐    ┌─────────────────┐
                    │ Context:         │    │ Scaling Actions │
                    │ performanceMetrics│    │ + Audit Trail   │
                    └──────────────────┘    └─────────────────┘
```

### Component Integration

**1. function-rds-metrics**
- Fetches CloudWatch metrics: CPU, memory, IOPS, connections, storage
- Writes to both `status.performanceMetrics` and `context.performanceMetrics`
- Provides structured metric data with timestamps and units

**2. function-claude** 
- Reads metrics from pipeline context via `contextFields: ["performanceMetrics"]`
- Analyzes complex observed resources (300+ line YAML with full metadata)
- Makes scaling decisions using Claude Sonnet 4.0 with configurable token limits
- Returns clean desired spec (no system fields) for server-side apply

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
kind: XSQLInstance
metadata:
  name: my-intelligent-db
spec:
  compositionSelector:
    matchLabels:
      type: intelligent
      scaling: ai-driven
  parameters:
    engine: mariadb
    engineVersion: "10.11"
    storageGB: 20
    region: us-west-2
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

## Testing

The configuration can be tested using:

- `up composition render --xrd=apis/definition.yaml apis/composition.yaml examples/mariadb-xr.yaml` to render the MariaDB composition
- `up composition render --xrd=apis/definition.yaml apis/composition.yaml examples/postgres-xr.yaml` to render the PostgreSQL composition  
- `up composition render --xrd=apis/definition.yaml apis/composition-intelligent.yaml examples/mariadb-xr-intelligent.yaml` to render the intelligent scaling composition
- `up test run tests/*` to run composition tests
- `up test run tests/* --e2e` to run end-to-end tests

## Deployment

- Execute `up project run`
- Alternatively, install the Configuration from the [Upbound Marketplace](https://marketplace.upbound.io/configurations/upbound/configuration-aws-database)
- Check [examples](/examples/) for example XR(Composite Resource)

## Next steps

This repository serves as a foundational step. To enhance the configuration, consider:

1. create new API definitions in this same repo
2. editing the existing API definition to your needs

To learn more about how to build APIs for your managed control planes in Upbound, read the guide on [Upbound's docs](https://docs.upbound.io/).