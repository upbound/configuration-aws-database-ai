import models.io.upbound.awsm.rds.v1beta1 as rdsv1beta1
import models.io.upbound.platform.aws.v1alpha1 as platformawsv1alpha1

import base64

oxr = platformawsv1alpha1.SQLInstance{**option("params").oxr} # observed composite resource
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
            # V2: writeConnectionSecretToRef no longer has namespace field (written to resource namespace)
            writeConnectionSecretToRef = {
                name = "{}-sql".format(oxr.metadata.uid)
            }
        }
    }
    {
        apiVersion: "meta.krm.kcl.dev/v1alpha1"
        kind: "CompositeConnectionDetails"
        if "RDSInstanceSmall" in ocds:
            data: {
                endpoint = ocds["RDSInstanceSmall"].Resource?.status?.atProvider?.endpoint
                host = ocds["RDSInstanceSmall"].Resource?.status?.atProvider?.address
                username = base64.encode(ocds["RDSInstanceSmall"].Resource?.spec?.forProvider?.username)
                password = ocds["RDSInstanceSmall"].ConnectionDetails.password
            }
        else:
            data: {}
    }
]
items = _items
