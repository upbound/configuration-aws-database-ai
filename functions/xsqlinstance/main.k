import models.io.upbound.aws.rds.v1beta1 as rdsv1beta1
import models.io.upbound.platform.aws.v1alpha1 as platformawsv1alpha1

import base64

oxr = platformawsv1alpha1.XSQLInstance{**option("params").oxr} # observed composite resource
ocds = option("params").ocds # observed composite resource
oxrParams = oxr.spec.parameters

defaultSpec = {
    providerConfigRef.name = oxr.spec.parameters.providerConfigName or "default"
    deletionPolicy = oxr.spec.parameters.deletionPolicy
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
        metadata: _metadata("RDSInstanceSmall")
        spec: defaultSpec | {
            forProvider: {
                dbName = "upbound"
                dbSubnetGroupNameSelector.matchControllerRef = True
                instanceClass = "db.t3.micro"
                identifier = oxr.metadata.name
                publiclyAccessible = False
                skipFinalSnapshot = True
                username = "masteruser"
                engine = oxrParams.engine
                engineVersion = oxrParams.engineVersion
                allocatedStorage = oxrParams.storageGB
                vpcSecurityGroupIdSelector.matchLabels = {
                    "networks.aws.platform.upbound.io/network-id" = oxrParams.networkRef.id
                }
                autoGeneratePassword = oxrParams.autoGeneratePassword
                passwordSecretRef = {
                    name = oxrParams.passwordSecretRef.name
                    namespace = oxrParams.passwordSecretRef.namespace
                    key = oxrParams.passwordSecretRef.key

                }
            }
            writeConnectionSecretToRef = {
                name = "{}-sql".format(oxr.metadata.uid)
                namespace = oxr.spec.writeConnectionSecretToRef.namespace
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
