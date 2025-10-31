# Crossplane v2 Migration Guide

This guide documents the migration from Crossplane v1 to v2 for this AWS RDS configuration, including all breaking changes and lessons learned.

## Overview

Crossplane v2 introduces **namespaced resources** with the `.m` API group suffix (e.g., `rds.aws.m.upbound.io/v1beta1`) and removes the XR/Claim separation pattern. This migration covers updating XRDs, compositions, KCL functions, and tests.

## Prerequisites

- Upgrade `upbound.yaml` to reference v2 provider packages
- Run `up project build` to generate v2 models in `.up/kcl/models/`
- Ensure Docker is running for composition rendering tests

## Breaking Changes

### 1. XRD API Version and Structure

**Before (v1):**
```yaml
apiVersion: apiextensions.crossplane.io/v1
kind: CompositeResourceDefinition
metadata:
  name: xsqlinstances.aws.platform.upbound.io
spec:
  claimNames:
    kind: SQLInstance
    plural: sqlinstances
  connectionSecretKeys:
    - username
    - password
  group: aws.platform.upbound.io
  names:
    kind: XSQLInstance
    plural: xsqlinstances
```

**After (v2):**
```yaml
apiVersion: apiextensions.crossplane.io/v2
kind: CompositeResourceDefinition
metadata:
  name: sqlinstances.aws.platform.upbound.io
spec:
  scope: Namespaced  # NEW: Required in v2
  group: aws.platform.upbound.io
  names:
    kind: SQLInstance  # Removed "X" prefix
    plural: sqlinstances
  # claimNames removed - claims not supported in v2
  # connectionSecretKeys moved or handled differently
```

**Key Changes:**
- ✅ Update to `apiVersion: apiextensions.crossplane.io/v2`
- ✅ Add `scope: Namespaced` (or `Cluster` if needed)
- ✅ Remove `claimNames` - v2 namespaced resources don't support claims
- ✅ Remove "X" prefix from resource names (`XSQLInstance` → `SQLInstance`)
- ✅ Update metadata name to match new plural

### 2. Namespaced Resource API Groups

**Before (v1 - cluster-scoped):**
```kcl
import models.io.upbound.aws.rds.v1beta1 as rdsv1beta1
```

**After (v2 - namespaced):**
```kcl
import models.io.upbound.awsm.rds.v1beta1 as rdsv1beta1
// Note the "awsm" instead of "aws" - the .m indicates namespaced
```

**API Version Changes:**
- Cluster-scoped v1: `rds.aws.upbound.io/v1beta1`
- Namespaced v2: `rds.aws.m.upbound.io/v1beta1`

The `.m` suffix indicates **managed/namespaced** resources in v2.

### 3. deletionPolicy Removed for Namespaced Resources

**Before (v1):**
```kcl
defaultSpec = {
    providerConfigRef.name = "default"
    deletionPolicy = oxr.spec.parameters.deletionPolicy  // "Delete" or "Orphan"
    forProvider.region = "us-west-2"
}
```

**After (v2):**
```kcl
defaultSpec = {
    providerConfigRef = {
        kind = "ProviderConfig"  // Now required!
        name = "default"
    }
    managementPolicies = ["*"]  // Replaces deletionPolicy
    forProvider.region = "us-west-2"
}
```

**Migration Path:**
- Default behavior (`deletionPolicy: Delete`) → `managementPolicies: ["*"]`
- Orphan behavior (`deletionPolicy: Orphan`) → `managementPolicies: ["Create", "Observe", "Update"]`

**XRD Schema Update:**
```yaml
parameters:
  type: object
  properties:
    managementPolicies:
      description: ManagementPolicies for the RDS resources. Defaults to ["*"] which includes all operations (Create, Observe, Update, Delete). To orphan resources on deletion, use ["Create", "Observe", "Update"].
      type: array
      items:
        type: string
        enum:
          - "*"
          - Create
          - Observe
          - Update
          - Delete
      default: ["*"]
```

### 4. providerConfigRef Requires kind Field

**Before (v1):**
```kcl
providerConfigRef.name = "default"
```

**After (v2):**
```kcl
providerConfigRef = {
    kind = "ProviderConfig"  // REQUIRED in v2
    name = "default"
}
```

**Error if missing:**
```
attribute 'kind' of RdsAwsmUpboundIoV1beta1SubnetGroupSpecProviderConfigRef is required and can't be None or Undefined
```

### 5. namespace Field Removed from Secret References

**Before (v1):**
```kcl
passwordSecretRef = {
    name = "mariadbsecret"
    namespace = "default"  // Explicit namespace
    key = "password"
}

writeConnectionSecretToRef = {
    name = "{}-sql".format(oxr.metadata.uid)
    namespace = oxr.spec.writeConnectionSecretToRef.namespace
}
```

**After (v2):**
```kcl
passwordSecretRef = {
    name = "mariadbsecret"
    // namespace removed - inferred from resource namespace
    key = "password"
}

writeConnectionSecretToRef = {
    name = "{}-sql".format(oxr.metadata.uid)
    // namespace removed - written to resource namespace
}
```

**XRD Schema Update:**
```yaml
passwordSecretRef:
  type: object
  description: "A reference to the Secret object containing database password. In v2, namespace is inferred from the resource namespace."
  properties:
    namespace:
      type: string
      description: "Deprecated in v2 - namespace is now inferred from resource namespace"
    name:
      type: string
    key:
      type: string
  required:
    - name
    - key
    # namespace no longer required
```

### 6. compositionSelector Moved to spec.crossplane

**Before (v1):**
```yaml
apiVersion: aws.platform.upbound.io/v1alpha1
kind: XSQLInstance
metadata:
  name: my-database
spec:
  compositionSelector:
    matchLabels:
      type: rds-metrics
  parameters:
    region: us-west-2
```

**After (v2):**
```yaml
apiVersion: aws.platform.upbound.io/v1alpha1
kind: SQLInstance
metadata:
  name: my-database
  namespace: default  # Now required for namespaced resources
spec:
  crossplane:  # NEW: Crossplane-specific fields under this section
    compositionSelector:
      matchLabels:
        type: rds-metrics
  parameters:
    region: us-west-2
```

All "Crossplane machinery" fields move under `spec.crossplane` to distinguish Crossplane-specific configuration from user-facing parameters.

### 7. Connection Secrets Completely Rearchitected in v2

**⚠️ CRITICAL BREAKING CHANGE**: Crossplane v2 removes built-in connection secret support from XRs entirely. This is one of the most significant architectural changes in v2.

#### What Changed

**Before (v1):**
```yaml
apiVersion: aws.platform.upbound.io/v1alpha1
kind: XSQLInstance
spec:
  parameters:
    region: us-west-2
  writeConnectionSecretToRef:
    name: my-connection-secret
    namespace: default
```

XRs had built-in `spec.writeConnectionSecretToRef` that automatically created a Kubernetes Secret with aggregated connection details from all composed resources.

**After (v2):**
```yaml
apiVersion: aws.platform.upbound.io/v1alpha1
kind: SQLInstance
metadata:
  namespace: default
spec:
  parameters:
    region: us-west-2
  # writeConnectionSecretToRef completely removed - not supported in v2 XRs
```

**The field is gone.** There is no automatic connection secret creation for v2 XRs.

#### The v2 Philosophy

According to [crossplane/crossplane#6440](https://github.com/crossplane/crossplane/issues/6440), Crossplane v2 shifts to representing higher-level abstractions (complete applications) rather than low-level infrastructure. Connection secrets are no longer a built-in feature because:

1. Not all XRs need to expose connection details
2. Different use cases need different secret structures
3. Functions provide more flexibility for secret composition

#### Migration Path: Manually Compose Secrets

The official guidance from Nic Cope (Crossplane maintainer):

> "In v2 you can recreate it using functions - just have your XR compose a secret with the XR's connection details in it."

This means your **function must explicitly create a Kubernetes Secret resource** containing the connection details.

#### Implementation Example

**Step 1: Managed resources still support connection secrets**

```kcl
rdsv1beta1.Instance{
    metadata: _metadata("rds-instance")
    spec: {
        forProvider: {
            engine = "postgres"
            username = "masteruser"
            # ... other config
        }
        # Managed resources can still write connection secrets
        writeConnectionSecretToRef = {
            name = "{}-rds-conn".format(oxr.metadata.name)
        }
    }
}
```

This creates a Secret with raw RDS credentials that the function can read via `ocds["rds-instance"].ConnectionDetails`.

**Step 2: Function composes a user-facing Secret**

```kcl
import models.io.k8s.api.core.v1 as corev1

# V2: Manually compose a Kubernetes Secret with connection details
corev1.Secret{
    metadata: _metadata("connection-secret") | {
        name: "{}-connection".format(oxr.metadata.name)
        namespace: oxr.metadata.namespace
        labels: {
            "crossplane.io/composite": oxr.metadata.name
        }
    }
    type: "connection.crossplane.io/v1alpha1"
    if "rds-instance" in ocds:
        data: {
            # Base64-encode all values except password (already encoded)
            endpoint: base64.encode(ocds["rds-instance"].Resource?.status?.atProvider?.endpoint or "")
            host: base64.encode(ocds["rds-instance"].Resource?.status?.atProvider?.address or "")
            port: base64.encode(str(ocds["rds-instance"].Resource?.status?.atProvider?.port or 3306))
            username: base64.encode(ocds["rds-instance"].Resource?.spec?.forProvider?.username or "")
            # Password comes from managed resource's connection secret
            password: ocds["rds-instance"].ConnectionDetails?.password or ""
        }
    else:
        data: {}
}
```

**Note**: Add Kubernetes API dependency to `upbound.yaml` to generate Secret models:

```yaml
apiVersion: meta.dev.upbound.io/v2alpha1
kind: Project
spec:
  apiDependencies:
  - k8s:
      version: v1.33.0
    type: k8s
```

Then run `up project build` to generate models in `.up/kcl/models/io/k8s/api/core/v1/Secret.k`.

**Step 3: Users reference the composed Secret**

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: app
spec:
  containers:
  - name: app
    env:
    - name: DB_HOST
      valueFrom:
        secretKeyRef:
          name: my-database-connection  # {sqlinstance-name}-connection
          key: host
```

#### What About CompositeConnectionDetails?

❌ **DON'T USE** `CompositeConnectionDetails` for v2:

```kcl
# This is NOT sufficient in v2!
{
    apiVersion: "meta.krm.kcl.dev/v1alpha1"
    kind: "CompositeConnectionDetails"
    data: {
        endpoint = ocds["rds-instance"].Resource?.status?.atProvider?.endpoint
    }
}
```

`CompositeConnectionDetails` only exposes data in the XR's `.status.connectionDetails` field. It does **NOT** create a Kubernetes Secret that applications can reference.

#### Architecture Comparison

**v1 Built-in:**
```
XR (writeConnectionSecretToRef)
  └─> Crossplane creates Secret automatically ✅
```

**v2 Function-based:**
```
XR (no built-in support)
  └─> Function generates:
      ├─> Managed Resource (writeConnectionSecretToRef)
      │     └─> Creates Secret with raw credentials
      └─> Kubernetes Secret resource (manually composed) ✅
            └─> Aggregates connection details for user consumption
```

#### XRD Schema Changes

Remove connection secret fields from the XRD:

```yaml
# v1 XRD - REMOVE THESE
spec:
  connectionSecretKeys:
    - username
    - password
    - endpoint
    - port

  # In openAPIV3Schema
  spec:
    properties:
      writeConnectionSecretToRef:  # REMOVE
        type: object
        properties:
          name:
            type: string
          namespace:
            type: string
```

```yaml
# v2 XRD - No connection secret fields
spec:
  scope: Namespaced
  # connectionSecretKeys removed
  # No writeConnectionSecretToRef in schema
```

#### Documentation Gap

⚠️ **Warning**: As noted in [crossplane/docs#1001](https://github.com/crossplane/docs/issues/1001), this breaking change is poorly documented:

- No official migration guide exists yet
- The only "documentation" is scattered GitHub issue comments
- Users discover this during migration, often causing confusion

This guide provides the first comprehensive documentation of this change.

## Migration Checklist

### Step 1: Update upbound.yaml Dependencies

```yaml
dependsOn:
  - apiVersion: pkg.crossplane.io/v1
    kind: Provider
    package: xpkg.upbound.io/upbound/provider-aws-rds
    version: v2  # Update to v2
```

### Step 2: Migrate XRD

- [ ] Update `apiVersion: apiextensions.crossplane.io/v2`
- [ ] Add `scope: Namespaced`
- [ ] Remove `claimNames` section
- [ ] Remove "X" prefix from `kind` and update `plural`
- [ ] Update `metadata.name` to match new plural
- [ ] Add `managementPolicies` parameter (remove `deletionPolicy`)
- [ ] Make `passwordSecretRef.namespace` optional with deprecation note

### Step 3: Update KCL Function Imports

```kcl
// Change all provider imports from .aws. to .awsm.
import models.io.upbound.awsm.rds.v1beta1 as rdsv1beta1
import models.io.upbound.awsm.v1beta1 as awsv1beta1

// Update XR type
oxr = platformawsv1alpha1.SQLInstance{**option("params").oxr}
```

### Step 4: Update Function Code

- [ ] Update `providerConfigRef` to include `kind` field
- [ ] Replace `deletionPolicy` with `managementPolicies`
- [ ] Remove `namespace` from `passwordSecretRef`
- [ ] Remove `namespace` from `writeConnectionSecretToRef` (on managed resources)
- [ ] Update all `XSQLInstance` references to `SQLInstance`
- [ ] **CRITICAL**: Replace `CompositeConnectionDetails` with manually composed Kubernetes Secret
  - Add `import base64` to function
  - Create a `v1/Secret` resource in function output
  - Populate `data` fields with base64-encoded connection details from `ocds`
  - Use `ocds["resource-name"].ConnectionDetails.password` for password
  - Use `ocds["resource-name"].Resource?.status?.atProvider?.field` for other fields

### Step 5: Update Compositions

```yaml
spec:
  compositeTypeRef:
    apiVersion: aws.platform.upbound.io/v1alpha1
    kind: SQLInstance  # Remove "X" prefix
```

### Step 6: Update Examples

- [ ] Change kind from `XSQLInstance` to `SQLInstance`
- [ ] Add `namespace: default` to metadata
- [ ] Move `compositionSelector` to `spec.crossplane.compositionSelector`
- [ ] Remove `namespace` from `passwordSecretRef`
- [ ] Remove `writeConnectionSecretToRef` from spec

### Step 7: Update Tests

- [ ] Update imports to use `awsm` models
- [ ] Change all `XSQLInstance` to `SQLInstance`
- [ ] Add `providerConfigRef.kind` to expected resources
- [ ] Add `managementPolicies` to expected resources
- [ ] Remove `namespace` from `passwordSecretRef` in assertions
- [ ] Remove `writeConnectionSecretToRef` from XR assertions

### Step 8: Build and Test

```bash
# Rebuild to generate v2 models
up project build

# Test composition rendering (requires Docker)
up composition render \
  --xrd=apis/definition.yaml \
  apis/composition-rds-metrics.yaml \
  examples/mariadb-xr-rds-metrics.yaml

# Run composition tests
up test run tests/test-xsqlinstance/
```

## Common Errors and Solutions

### Error: "Cannot add member 'deletionPolicy'"

**Cause:** v2 namespaced resources don't have `deletionPolicy` field.

**Solution:** Replace with `managementPolicies`:
```kcl
managementPolicies = oxr.spec.parameters.managementPolicies or ["*"]
```

### Error: "Cannot add member 'namespace' to schema"

**Cause:** v2 removes explicit namespace from secret references.

**Solution:** Remove namespace field:
```kcl
passwordSecretRef = {
    name = "secret-name"
    key = "password"
    // namespace removed
}
```

### Error: "attribute 'kind' of ProviderConfigRef is required"

**Cause:** v2 requires explicit `kind` in provider config references.

**Solution:**
```kcl
providerConfigRef = {
    kind = "ProviderConfig"
    name = "default"
}
```

### Error: "Schema does not contain attribute compositionSelector"

**Cause:** v2 moves Crossplane fields under `spec.crossplane`.

**Solution:**
```yaml
spec:
  crossplane:
    compositionSelector:
      matchLabels:
        type: rds-metrics
```

### Error: "Cannot add member 'writeConnectionSecretToRef'" (in XR spec)

**Cause:** v2 XRD schema removes `writeConnectionSecretToRef` from XR specs entirely.

**Solution:**
1. Remove from XR examples and test assertions
2. Implement manual Secret composition in your function (see Section 7)
3. Keep `writeConnectionSecretToRef` on managed resources - that's still supported

### Error: "Connection secrets not being created"

**Cause:** Migrated from v1 but didn't implement manual Secret composition.

**Symptoms:**
- No Secret created for the XR
- Applications can't find connection details
- Only managed resources have connection secrets

**Solution:** Implement function-based Secret composition:

```kcl
import base64

_items = [
    # ... your managed resources with writeConnectionSecretToRef ...

    # Add this: Manually compose connection Secret
    {
        apiVersion: "v1"
        kind: "Secret"
        metadata: _metadata("connection-secret") | {
            name: "{}-connection".format(oxr.metadata.name)
            namespace: oxr.metadata.namespace
        }
        type: "connection.crossplane.io/v1alpha1"
        if "your-managed-resource-name" in ocds:
            data: {
                endpoint: base64.encode(ocds["resource-name"].Resource?.status?.atProvider?.endpoint or "")
                password: ocds["resource-name"].ConnectionDetails?.password or ""
                # ... other fields
            }
        else:
            data: {}
    }
]
```

### Error: "CompositeConnectionDetails not creating a Secret"

**Cause:** `CompositeConnectionDetails` only updates XR status, it doesn't create a Kubernetes Secret.

**Symptoms:**
- Data appears in `kubectl get xr -o yaml` under `status.connectionDetails`
- No Secret resource created
- Applications can't reference the data

**Solution:** Replace `CompositeConnectionDetails` with a manually composed `v1/Secret` resource (see Section 7).

## Testing Strategy

### Unit Tests (Composition Tests)

Create credentials file for external functions:
```yaml
# tests/test-credentials.yaml
apiVersion: v1
kind: Secret
metadata:
  name: aws-creds
  namespace: crossplane-system
type: Opaque
data:
  credentials: <base64-encoded-aws-credentials>
```

Run tests with credentials:
```bash
up test run tests/test-xsqlinstance/ \
  --function-credentials=tests/test-credentials.yaml
```

### E2E Tests

Ensure your e2e tests:
- Include proper ProviderConfig with v2 structure
- Use namespaced resources
- Reference v2 provider packages

## Best Practices

1. **Incremental Migration**: Test each component separately
   - XRD changes first
   - Function code second
   - Tests last

2. **Model Generation**: Always run `up project build` after dependency updates to regenerate models

3. **Namespace Handling**: Be explicit about resource namespaces in v2
   ```yaml
   metadata:
     name: my-resource
     namespace: default  # Always specify for namespaced resources
   ```

4. **Composition Selection**: Use `spec.crossplane` for all Crossplane-specific fields
   ```yaml
   spec:
     crossplane:
       compositionSelector:
         matchLabels:
           provider: aws
     parameters:
       # User-facing parameters here
   ```

5. **Provider Package Names**: Always use fully qualified package names
   ```yaml
   package: xpkg.upbound.io/upbound/provider-aws-rds
   # NOT: provider-aws-rds
   ```

## Reference Documentation

- [Crossplane v2 Upgrade Guide](https://docs.crossplane.io/latest/guides/upgrade-to-crossplane-v2/)
- [What's New in v2](https://docs.crossplane.io/latest/whats-new/)
- [Upbound DevEx Documentation](https://docs.crossplane.io/)

## Version History

- **v1 (Legacy)**: Cluster-scoped resources with XR/Claim pattern
- **v2 (Current)**: Namespaced resources with simplified API structure

## Troubleshooting

### Models Not Updating

**Problem:** Changes to provider version not reflected in generated models.

**Solution:**
```bash
rm -rf .up/
up project build
```

### Function Compilation Errors

**Problem:** KCL schema validation errors after migration.

**Solution:** Check `.up/kcl/models/` for the actual generated schemas. The v2 schemas are structurally different.

### Test Failures

**Problem:** Tests pass locally but fail in CI.

**Solution:** Ensure Docker is available in CI environment for composition rendering.

## Conclusion

Crossplane v2 simplifies resource management by:
- Removing the XR/Claim abstraction
- Using namespaced resources for better multi-tenancy
- Consolidating Crossplane-specific fields under `spec.crossplane`
- Inferring namespaces for secret references

The migration requires careful attention to breaking changes but results in cleaner, more intuitive APIs.
