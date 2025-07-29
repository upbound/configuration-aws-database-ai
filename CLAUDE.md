# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

This is an Upbound Crossplane configuration for AWS databases that provides a foundational setup for deploying and managing RDS instances. The configuration uses pipeline-mode composition with embedded KCL functions to create a custom XSQLInstance API that supports both PostgreSQL and MariaDB engines.

## Architecture

### Core Structure
- **XRD (CompositeResourceDefinition)**: `apis/definition.yaml` defines the XSQLInstance custom resource API with connection secret keys (username, password, endpoint, host)
- **Composition**: `apis/composition.yaml` uses pipeline-mode with embedded KCL function and auto-ready function
- **Embedded Function**: `functions/xsqlinstance/main.k` contains KCL logic that creates RDS SubnetGroup and Instance resources
- **Tests**: `tests/test-xsqlinstance/` and `tests/e2etest-xsqlinstance/` contain KCL composition tests
- **Examples**: `examples/mariadb-xr.yaml` and `examples/postgres-xr.yaml` provide sample configurations

### Key Components
- **XSQLInstance API**: Custom resource supporting postgres/mariadb engines with configurable storage, networking, and authentication
- **Network Integration**: References external network configurations via networkRef.id selector
- **Secret Management**: Supports both password secret references and auto-generated passwords
- **Connection Secrets**: Automatically exposes database connection details (endpoint, host, username, password)

## Development Commands

### Core Upbound DevEx Workflow
```bash
# Build the project and package functions
up project build

# Deploy the configuration to control plane
up project run

# Test composition rendering with examples
up composition render --xrd=apis/definition.yaml apis/composition.yaml examples/mariadb-xr.yaml
up composition render --xrd=apis/definition.yaml apis/composition.yaml examples/postgres-xr.yaml

# Run composition tests
up test run tests/*

# Run end-to-end tests  
up test run tests/* --e2e
```

### Testing and Validation Commands
```bash
# Render specific database engine compositions
up composition render --xrd=apis/definition.yaml apis/composition.yaml examples/mariadb-xr.yaml
up composition render --xrd=apis/definition.yaml apis/composition.yaml examples/postgres-xr.yaml

# Run unit tests for composition logic
up test run tests/test-xsqlinstance/

# Run e2e tests with actual cloud resources
up test run tests/e2etest-xsqlinstance/ --e2e
```

## Key Files

- `upbound.yaml`: Project metadata with dependencies on provider-aws-rds and configuration-aws-network
- `apis/definition.yaml`: XSQLInstance XRD with engine selection (postgres/mariadb), storage, networking, and authentication parameters
- `apis/composition.yaml`: Pipeline composition referencing embedded xsqlinstance function and auto-ready function
- `functions/xsqlinstance/main.k`: KCL function creating RDS SubnetGroup and Instance with network integration
- `examples/`: MariaDB and PostgreSQL example XRs showing typical usage patterns
- `tests/`: KCL-based composition tests validating rendered resources match expected output

## Function Implementation Details

### XSQLInstance Function Logic (`functions/xsqlinstance/main.k`)
- Creates RDS SubnetGroup with network selector matching networkRef.id
- Creates RDS Instance with configurable engine (postgres/mariadb), storage, and authentication
- Uses network security group and subnet selectors for proper VPC integration
- Handles both auto-generated passwords and secret references
- Exports connection details (endpoint, host, username, password) via CompositeConnectionDetails

### Resource Dependencies
- Depends on `configuration-aws-network` v0.24.0 for networking infrastructure
- Uses `provider-aws-rds` v1 for RDS resource management
- Requires `function-auto-ready` for composition readiness management

## Testing Architecture

### Comprehensive Test Coverage (`tests/test-xsqlinstance/main.k`)
**MariaDB and PostgreSQL Tests validate:**
- RDS SubnetGroup with network integration 
- RDS Instance with standard configuration (db.t3.micro, auto-generated passwords)
- Proper resource annotations, labels, and owner references
- Network integration via label selectors
- Auto-generated and referenced password configurations

### Test Structure
- Uses `CompositionTest` resources with 60-second timeout
- Validation disabled for faster testing
- Tests cover both MariaDB (10.11) and PostgreSQL (13.18) engines
- Tests verify proper secret handling and connection details

### Expected Resource Output  
Each XSQLInstance creates:
1. **RDS SubnetGroup** with network-id label selector
2. **RDS Instance** with standard monitoring and networking configuration
3. **CompositeConnectionDetails** with database connection information (endpoint, host, username, password)

## Configuration Parameters

### Required XSQLInstance Parameters
- `region`: AWS region for resource deployment
- `engine`: Database engine (postgres or mariadb)
- `engineVersion`: Specific engine version string
- `storageGB`: Allocated storage in GB
- `networkRef.id`: Reference to network configuration
- `passwordSecretRef`: Secret reference for database password (namespace, name, key)

### Optional Parameters
- `deletionPolicy`: Delete or Orphan (defaults to Delete)
- `providerConfigName`: Crossplane ProviderConfig name (defaults to "default")  
- `autoGeneratePassword`: Enable automatic password generation

## Intelligent Scaling Integration

This configuration is designed to work with the `function-rds-metrics` prototype for intelligent scaling capabilities.

### Scaling Architecture
- **Pure Function Approach**: Uses `function-rds-metrics` Crossplane function to directly pull CloudWatch metrics
- **Proactive Scaling**: Function evaluates metrics and makes scaling decisions within the composition pipeline
- **No External Dependencies**: Eliminates need for CloudWatch alarms, SNS topics, or Lambda functions

### Scaling Parameters
The following RDS parameters can be dynamically scaled:
- **instanceClass**: Vertical scaling (db.t3.micro → db.t3.small → db.t3.medium, etc.)
- **allocatedStorage**: Storage expansion (minimum increments vary by storage type)
- **iops**: IOPS scaling (for provisioned IOPS storage)
- **storageType**: Storage type migration (gp2 → gp3 → io1/io2)

### Metrics Integration
Standard CloudWatch metrics evaluated by the function:
- **CPUUtilization**: Threshold 70% for scale-up trigger
- **DatabaseConnections**: 80% of max_connections for connection pressure
- **FreeableMemory**: Monitor memory pressure for instance scaling
- **FreeStorageSpace**: Monitor storage utilization for storage scaling

### Test Load Generation
For e2e testing and demos, use tools like:
- **pgbench** (PostgreSQL): `pgbench -h <endpoint> -U masteruser -c 10 -t 1000 upbound`
- **mysqlslap** (MariaDB): `mysqlslap --host=<endpoint> --user=masteruser --concurrency=10 --iterations=100`
- **sysbench**: Multi-engine load testing tool