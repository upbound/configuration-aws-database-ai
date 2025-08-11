import models.io.upbound.aws.rds.v1beta1 as rdsv1beta1
import models.io.upbound.dev.meta.v1alpha1 as metav1alpha1
import models.io.upbound.platform.aws.v1alpha1 as platformawsv1alpha1

_items = [
    metav1alpha1.CompositionTest{
        metadata.name: "TestMariaDB"
        spec = {
            assertResources: [
                platformawsv1alpha1.XSQLInstance{
                    metadata = {
                        name = "configuration-aws-database-mariadb"
                    }
                    spec = {
                        parameters = {
                            autoGeneratePassword = True
                            engine = "mariadb"
                            engineVersion = "10.11"
                            networkRef = {
                                id = "configuration-aws-database"
                            }
                            passwordSecretRef = {
                                key = "password"
                                name = "mariadbsecret"
                                namespace = "default"
                            }
                            region = "us-west-2"
                            storageGB = 5
                            instanceClass = "db.t3.micro"
                        }
                        writeConnectionSecretToRef = {
                            name = "configuration-aws-database-mariadb"
                            namespace = "default"
                        }
                    }
                }
                rdsv1beta1.Instance{
                    metadata = {
                        annotations = {
                            "crossplane.io/composition-resource-name" = "RDSInstanceSmall"
                        }
                        generateName = "configuration-aws-database-mariadb-"
                        labels = {
                            "crossplane.io/composite" = "configuration-aws-database-mariadb"
                        }
                        ownerReferences = [
                            {
                                apiVersion = "aws.platform.upbound.io/v1alpha1"
                                blockOwnerDeletion = True
                                controller = True
                                kind = "XSQLInstance"
                                name = "configuration-aws-database-mariadb"
                                uid = ""
                            }
                        ]
                    }
                    spec = {
                        forProvider = {
                            allocatedStorage = 5
                            autoGeneratePassword = True
                            dbName = "upbound"
                            dbSubnetGroupNameSelector = {
                                matchControllerRef = True
                            }
                            engine = "mariadb"
                            engineVersion = "10.11"
                            instanceClass = "db.t3.micro"
                            passwordSecretRef = {
                                key = "password"
                                name = "mariadbsecret"
                                namespace = "default"
                            }
                            publiclyAccessible = False
                            region = "us-west-2"
                            skipFinalSnapshot = True
                            username = "masteruser"
                            vpcSecurityGroupIdSelector = {
                                matchLabels = {
                                    "networks.aws.platform.upbound.io/network-id" = "configuration-aws-database"
                                }
                            }
                        }
                    }
                }
                rdsv1beta1.SubnetGroup{
                    metadata = {
                        annotations = {
                            "crossplane.io/composition-resource-name" = "compositeSQLInstanceDbSubnetGroup"
                        }
                        generateName = "configuration-aws-database-mariadb-"
                        labels = {
                            "crossplane.io/composite" = "configuration-aws-database-mariadb"
                        }
                        ownerReferences = [
                            {
                                apiVersion = "aws.platform.upbound.io/v1alpha1"
                                blockOwnerDeletion = True
                                controller = True
                                kind = "XSQLInstance"
                                name = "configuration-aws-database-mariadb"
                                uid = ""
                            }
                        ]
                    }
                    spec = {
                        forProvider = {
                            description = "An excellent formation of subnetworks."
                            region = "us-west-2"
                            subnetIdSelector = {
                                matchLabels = {
                                    "networks.aws.platform.upbound.io/network-id" = "configuration-aws-database"
                                }
                            }
                        }
                    }
                }
            ]
            compositionPath: "apis/composition.yaml"
            xrdPath: "apis/definition.yaml"
            xrPath: "examples/mariadb-xr.yaml"
            timeoutSeconds: 60
            validate: False
        }
    }
    metav1alpha1.CompositionTest{
        metadata.name: "TestPostgres"
        spec = {
            assertResources: [
                platformawsv1alpha1.XSQLInstance{
                    metadata = {
                        name = "configuration-aws-database-postgres"
                        namespace = "default"
                    }
                    spec = {
                        parameters = {
                            engine = "postgres"
                            engineVersion = "13.18"
                            networkRef = {
                                id = "configuration-aws-database"
                            }
                            passwordSecretRef = {
                                key = "password"
                                name = "psqlsecret"
                                namespace = "default"
                            }
                            region = "us-west-2"
                            storageGB = 5
                            instanceClass = "db.t3.micro"
                        }
                        writeConnectionSecretToRef = {
                            name = "configuration-aws-database-postgres"
                            namespace = "default"
                        }
                    }
                }
                rdsv1beta1.Instance{
                    metadata = {
                        annotations = {
                            "crossplane.io/composition-resource-name" = "RDSInstanceSmall"
                        }
                        generateName = "configuration-aws-database-postgres-"
                        labels = {
                            "crossplane.io/composite" = "configuration-aws-database-postgres"
                        }
                        ownerReferences = [
                            {
                                apiVersion = "aws.platform.upbound.io/v1alpha1"
                                blockOwnerDeletion = True
                                controller = True
                                kind = "XSQLInstance"
                                name = "configuration-aws-database-postgres"
                                uid = ""
                            }
                        ]
                    }
                    spec = {
                        forProvider = {
                            allocatedStorage = 5
                            dbName = "upbound"
                            dbSubnetGroupNameSelector = {
                                matchControllerRef = True
                            }
                            engine = "postgres"
                            engineVersion = "13.18"
                            instanceClass = "db.t3.micro"
                            passwordSecretRef = {
                                key = "password"
                                name = "psqlsecret"
                                namespace = "default"
                            }
                            publiclyAccessible = False
                            region = "us-west-2"
                            skipFinalSnapshot = True
                            username = "masteruser"
                            vpcSecurityGroupIdSelector = {
                                matchLabels = {
                                    "networks.aws.platform.upbound.io/network-id" = "configuration-aws-database"
                                }
                            }
                        }
                    }
                }
                rdsv1beta1.SubnetGroup{
                    metadata = {
                        annotations = {
                            "crossplane.io/composition-resource-name" = "compositeSQLInstanceDbSubnetGroup"
                        }
                        generateName = "configuration-aws-database-postgres-"
                        labels = {
                            "crossplane.io/composite" = "configuration-aws-database-postgres"
                        }
                        ownerReferences = [
                            {
                                apiVersion = "aws.platform.upbound.io/v1alpha1"
                                blockOwnerDeletion = True
                                controller = True
                                kind = "XSQLInstance"
                                name = "configuration-aws-database-postgres"
                                uid = ""
                            }
                        ]
                    }
                    spec = {
                        forProvider = {
                            description = "An excellent formation of subnetworks."
                            region = "us-west-2"
                            subnetIdSelector = {
                                matchLabels = {
                                    "networks.aws.platform.upbound.io/network-id" = "configuration-aws-database"
                                }
                            }
                        }
                    }
                }
            ]
            compositionPath: "apis/composition.yaml"
            xrdPath: "apis/definition.yaml"
            xrPath: "examples/postgres-xr.yaml"
            timeoutSeconds: 60
            validate: False
        }
    }
]
items= _items
