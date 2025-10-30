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

### 7. writeConnectionSecretToRef No Longer in XR Spec

**Before (v1):**
```yaml
spec:
  parameters:
    region: us-west-2
  writeConnectionSecretToRef:
    name: my-connection-secret
    namespace: default
```

**After (v2):**
```yaml
spec:
  parameters:
    region: us-west-2
  # writeConnectionSecretToRef removed from user-facing spec
  # Connection secrets handled automatically by Crossplane
```

The v2 XRD schema generator removes `writeConnectionSecretToRef` from the composite resource spec. Connection secret handling is now managed internally by Crossplane.

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
- [ ] Remove `namespace` from `writeConnectionSecretToRef`
- [ ] Update all `XSQLInstance` references to `SQLInstance`

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

### Error: "Cannot add member 'writeConnectionSecretToRef'"

**Cause:** v2 XRD schema removes this from user-facing spec.

**Solution:** Remove from XR examples and test assertions. Connection secrets are handled automatically.

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
