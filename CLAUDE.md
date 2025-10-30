# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

This is an **AI-powered Crossplane configuration for AWS databases** that combines traditional infrastructure-as-code with intelligent, automated scaling capabilities. The project provides a foundational setup for deploying and managing RDS instances that can automatically scale based on CloudWatch metrics analyzed by Claude AI.

## Architecture

### Core Components
- **XRD (CompositeResourceDefinition)**: `apis/definition.yaml` defines the XSQLInstance API with support for PostgreSQL and MariaDB engines
- **Multiple Composition Modes**:
  * Standard composition: `apis/composition.yaml` - Basic RDS deployment
  * Intelligent composition: `apis/composition-intelligent.yaml` - AI-driven scaling with Claude analysis
  * RDS metrics composition: `apis/composition-rds-metrics.yaml` - CloudWatch metrics integration
- **Embedded Function**: `functions/xsqlinstance/main.k` contains KCL logic for RDS SubnetGroup and Instance creation
- **AI Pipeline**: Uses `function-rds-metrics` → `function-claude` for intelligent scaling decisions
- **Crossplane Operations**: `operations/` directory contains CronOperation for scheduled scaling analysis

### Intelligent Scaling Pipeline
The AI-powered scaling system uses a 3-stage pipeline:
1. **Metrics Collection**: `function-rds-metrics` fetches CloudWatch data (CPU, memory, IOPS, connections)
2. **AI Analysis**: `function-claude` evaluates metrics against scaling thresholds using Claude Sonnet 4.0
3. **Resource Updates**: Dynamically scales instance class or storage based on AI recommendations

### Key Features
- **Multi-Engine Support**: PostgreSQL and MariaDB with configurable versions
- **Network Integration**: References external network configurations via `networkRef.id`
- **Intelligent Scaling**: AI-driven scaling decisions with full audit trails
- **Operations Integration**: Crossplane v2.0 Operations for scheduled and reactive scaling
- **Connection Secrets**: Automatic exposure of connection details (endpoint, host, username, password)

## Development Commands

### Core Upbound DevEx Workflow
```bash
# Build and deploy the configuration
up project build && up project run

# Test composition rendering for different modes
up composition render --xrd=apis/definition.yaml apis/composition.yaml examples/mariadb-xr.yaml
up composition render --xrd=apis/definition.yaml apis/composition-intelligent.yaml examples/mariadb-xr-intelligent.yaml
up composition render --xrd=apis/definition.yaml apis/composition-rds-metrics.yaml examples/mariadb-xr-rds-metrics.yaml

# Run composition tests
up test run tests/test-xsqlinstance/
up test run tests/e2etest-xsqlinstance/ --e2e
```

### AI Scaling System Setup
```bash
# Deploy Claude API credentials (required for intelligent scaling)
kubectl create secret generic claude \
  --from-literal=ANTHROPIC_API_KEY=your-api-key \
  -n crossplane-system

# Deploy with operations (includes CronOperation for scheduled scaling)
up project run  # Automatically includes operations/ directory

# Monitor scaling operations
kubectl get cronoperation,operation -n crossplane-system --watch
```

### Load Testing for Scaling Validation
```bash
# MySQL/MariaDB CPU stress test to trigger AI scaling
for i in {1..8}; do
    mysql \
      --host=your-rds-endpoint.region.rds.amazonaws.com \
      --user=masteruser \
      --password=your-password \
      --execute="SELECT BENCHMARK(1000000000, MD5('trigger_scaling_$i'));" &
done

# Monitor scaling decisions and instance changes
kubectl get xsqlinstance your-db-name -o jsonpath='{.status.claudeDecision}' | jq .
kubectl get instance.rds -l crossplane.io/composite=your-db-name -o jsonpath='{.items[0].spec.forProvider.instanceClass}'
```

## Key Files and Architecture

### Function Implementation (`functions/xsqlinstance/main.k`)
- Creates RDS SubnetGroup with network label selectors matching `networkRef.id`
- Creates RDS Instance with configurable engine, storage, authentication, and networking
- Handles both auto-generated passwords and secret references
- Exports connection details via CompositeConnectionDetails

### Intelligent Compositions
- **Standard**: Basic RDS deployment with auto-ready function
- **Intelligent**: Adds `function-rds-metrics` and `function-claude` for AI scaling
- **RDS Metrics**: Metrics collection without AI analysis

### Test Coverage (`tests/`)
- **Unit Tests**: `test-xsqlinstance/main.k` validates resource creation for MariaDB and PostgreSQL
- **E2E Tests**: `e2etest-xsqlinstance/main.k` performs full cloud deployment testing
- **Test Structure**: Uses `CompositionTest` resources with 60-second timeouts

### Operations Integration (`operations/`)
- **CronOperation**: Scheduled scaling analysis every 10 minutes for resources with `scale: me` label
- **Rate Limiting**: 5-minute cooldown to prevent scaling thrash
- **Conservative Scaling**: CPU >85%, Memory <15%, Connections >85% thresholds
- **Instance Progression**: `db.t3.micro → db.t3.small → db.t3.medium → db.t3.large`

## Dependencies and Integration

### Required Dependencies (`upbound.yaml`)
- **provider-aws-rds**: v1 - RDS resource management
- **configuration-aws-network**: v0.25.0-rc4-yury - Network infrastructure
- **function-auto-ready**: Composition readiness management
- **function-claude**: v0.2.0 - AI analysis and scaling decisions
- **function-rds-metrics**: v0.0.6 - CloudWatch metrics collection

### API Parameters
- **Required**: `region`, `engine`, `engineVersion`, `storageGB`, `networkRef.id`, `passwordSecretRef`
- **Optional**: `instanceClass` (default: db.t3.micro), `autoGeneratePassword`, `publiclyAccessible`, `deletionPolicy`
- **AI Status Fields**: `performanceMetrics`, `claudeDecision` with reasoning and timestamps

## Scaling Decision Process

### Input: CloudWatch Metrics
```yaml
performanceMetrics:
  metrics:
    CPUUtilization: { value: 1.98, unit: "Percent" }
    DatabaseConnections: { value: 0, unit: "Count" }
    FreeStorageSpace: { value: 2775404544, unit: "Bytes" }
```

### AI Analysis Thresholds
- **CPU >80%**: Scale up instance class
- **Memory <20% free**: Memory-optimized instance
- **IOPS >80%**: Increase storage or instance class
- **Connections >80%**: Larger instance class

### Output: Structured Decision
```yaml
status:
  claudeDecision:
    reasoning: "CPU utilization at 1.98% is well below 80% threshold..."
    timestamp: "2025-07-29T22:05:18Z"
```

## Production Usage Patterns

### Standard Database Deployment
Use `apis/composition.yaml` for basic RDS instances without AI scaling.

### AI-Powered Intelligent Scaling
Use `apis/composition-intelligent.yaml` with Claude API credentials for automated scaling based on real-time analysis.

### Operations-Based Scaling
Deploy with `up project run` to enable scheduled scaling analysis via Crossplane Operations.

### Monitoring and Observability
- **Scaling Decisions**: Captured in XSQLInstance `status.claudeDecision`
- **Performance Metrics**: Available in `status.performanceMetrics`
- **Audit Trail**: Full reasoning preserved for compliance
- **Cost Tracking**: ~$0.06-0.12 per scaling decision with Claude API

## Critical Implementation Notes

### AI Function Configuration
- **Token Limits**: Uses 8192 max tokens for handling complex YAML resources
- **Context Flow**: Metrics passed via `contextFields: ["performanceMetrics"]`
- **Safety**: Only scales up to prevent accidental downsizing
- **Schema Validation**: Returns clean desired spec without system fields

### Network Integration
- Requires `configuration-aws-network` for VPC, subnets, and security groups
- Uses label selectors with `networks.aws.platform.upbound.io/network-id` matching

### Secret Management
- Supports both referenced secrets and auto-generated passwords
- Connection secrets written to `upbound-system` namespace by default
- Claude API key must be stored as `claude` secret in `crossplane-system` namespace