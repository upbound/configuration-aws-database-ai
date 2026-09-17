import models.io.upbound.awsm.rds.v1beta1 as rdsv1beta1
import models.io.k8s.api.core.v1 as corev1

import base64

# Untyped on purpose. Constructing the generated SQLInstance schema from the
# observed XR fails once spec.crossplane.resourceRefs is populated - KCL will
# not coerce a plain list of dicts into a list of typed schema items, so it
# raises "expect [...SpecCrossplaneResourceRefsItems0], got list". A live XR
# always has resourceRefs after its first reconcile, and passing
# --observed-resources to `up composition render` reproduces it immediately.
oxr = option("params").oxr # observed composite resource
_dxr = option("params").dxr # desired composite resource
ocds = option("params").ocds # observed composite resource
oxrParams = oxr.spec.parameters

defaultSpec = {
    providerConfigRef = {
        kind = "ProviderConfig"
        name = oxr.spec.parameters.providerConfigName or "default"
    }
    managementPolicies = oxr.spec.parameters.managementPolicies or ["*"]
    forProvider.region = oxr.spec.parameters.region
}

_metadata = lambda name: str -> any {
    { annotations = { "krm.kcl.dev/composition-resource-name" = name }}
}

# Example to retrieve variables from "xr"; update as needed
# _region = "us-east-1"
# if oxr.spec?.parameters?.region:
#     _region = oxr.spec.parameters.region

_items = [
    rdsv1beta1.SubnetGroup{
        metadata: _metadata("compositeSQLInstanceDbSubnetGroup")
        spec = {
            **defaultSpec
            forProvider: {
                description = "An excellent formation of subnetworks."
                subnetIdSelector.matchLabels = {
                    "networks.aws.platform.upbound.io/network-id" = oxrParams.networkRef.id
                }
            }
        }
    }
    rdsv1beta1.Instance{
        metadata: _metadata("rds-instance")
        spec: defaultSpec | {
            forProvider: {
                dbName = "upbound"
                dbSubnetGroupNameSelector.matchControllerRef = True
                instanceClass = oxrParams.instanceClass
                applyImmediately = True
                identifier = oxr.metadata.name
                publiclyAccessible = oxrParams.publiclyAccessible or False
                skipFinalSnapshot = True
                username = "masteruser"
                engine = oxrParams.engine
                engineVersion = oxrParams.engineVersion
                allocatedStorage = oxrParams.storageGB
                vpcSecurityGroupIdSelector.matchLabels = {
                    "networks.aws.platform.upbound.io/network-id" = oxrParams.networkRef.id
                }
                autoGeneratePassword = oxrParams.autoGeneratePassword
                # V2: passwordSecretRef no longer has namespace field (inferred from resource namespace)
                passwordSecretRef = {
                    name = oxrParams.passwordSecretRef.name
                    key = oxrParams.passwordSecretRef.key
                }
            }
            # V2: Managed resources can still write connection secrets
            writeConnectionSecretToRef = {
                name = "{}-rds-conn".format(oxr.metadata.name)
            }
        }
    }
    # V2: XRs no longer have built-in connection secret support
    # Manually compose a Kubernetes Secret with connection details
    corev1.Secret{
        metadata: _metadata("connection-secret") | {
            name: "{}-connection".format(oxr.metadata.name)
            namespace: oxr.metadata.namespace
            labels: {
                "crossplane.io/composite": oxr.metadata.name
            }
            annotations: {
                "krm.kcl.dev/ready": "True"
            }
        }
        type: "connection.crossplane.io/v1alpha1"
        if "rds-instance" in ocds:
            data: {
                endpoint: base64.encode(ocds["rds-instance"].Resource?.status?.atProvider?.endpoint or "")
                host: base64.encode(ocds["rds-instance"].Resource?.status?.atProvider?.address or "")
                port: base64.encode(str(ocds["rds-instance"].Resource?.status?.atProvider?.port or 3306))
                username: base64.encode(ocds["rds-instance"].Resource?.spec?.forProvider?.username or "")
                password: ocds["rds-instance"].ConnectionDetails?.password or ""
            }
        else:
            data: {}
    }
]

# Surface what the RDS instance actually reports back onto the XR.
#
# The intelligent-scaling WatchOperation compares observedInstanceClass against
# spec.parameters.instanceClass: while they differ, a requested change has not
# landed yet and no new scaling decision is made. That is what replaces the
# wall-clock cooldown the CronOperation used to carry in its prompt - a model
# has no clock and cannot evaluate elapsed time, but it can compare two strings.
#
# observedInstanceStatus is the second gate, covering changes AWS makes that are
# not class changes (backing-up, maintenance) and the window after a patch is
# accepted but before the class itself flips.
if "rds-instance" in ocds:
    _dxr.status = {
        observedInstanceClass = ocds["rds-instance"].Resource?.status?.atProvider?.instanceClass or ""
        # atProvider.status, not instanceStatus - the RDS Instance schema calls
        # the lifecycle field "status" ("The RDS instance status.").
        observedInstanceStatus = ocds["rds-instance"].Resource?.status?.atProvider?.status or ""
    }

items = _items + [_dxr]
