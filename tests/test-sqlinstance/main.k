import models.io.upbound.awsm.rds.v1beta1 as rdsv1beta1
import models.io.upbound.dev.meta.v1alpha1 as metav1alpha1
import models.io.upbound.platform.aws.v1alpha1 as platformawsv1alpha1

_items = [
    metav1alpha1.CompositionTest{
        metadata.name: "test-mysql"
        spec = {
            assertResources: [
                platformawsv1alpha1.SQLInstance{
                    metadata = {
                        name = "rds-metrics-database-ai-mysql"
                        namespace = "database-team"
                    }
                    spec = {
                        parameters = {
                            autoGeneratePassword = True
                            engine = "mariadb"
                            engineVersion = "10.11"
                            publiclyAccessible = True
                            networkRef = {
                                id = "rds-metrics-database-ai-scale"
                            }
                            passwordSecretRef = {
                                key = "password"
                                name = "mariadbsecret"
                            }
                            region = "us-west-2"
                            storageGB = 5
                            instanceClass = "db.t3.micro"
                        }
                    }
                }
                rdsv1beta1.Instance{
                    metadata = {
                        annotations = {
                            "crossplane.io/composition-resource-name" = "rds-instance"
                        }
                        generateName = "rds-metrics-database-ai-mysql-"
                        labels = {
                            "crossplane.io/composite" = "rds-metrics-database-ai-mysql"
                        }
                        ownerReferences = [
                            {
                                apiVersion = "aws.platform.upbound.io/v1alpha1"
                                blockOwnerDeletion = True
                                controller = True
                                kind = "SQLInstance"
                                name = "rds-metrics-database-ai-mysql"
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
                            }
                            publiclyAccessible = True
                            region = "us-west-2"
                            skipFinalSnapshot = True
                            username = "masteruser"
                            vpcSecurityGroupIdSelector = {
                                matchLabels = {
                                    "networks.aws.platform.upbound.io/network-id": "rds-metrics-database-ai-scale"
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
                        generateName = "rds-metrics-database-ai-mysql-"
                        labels = {
                            "crossplane.io/composite" = "rds-metrics-database-ai-mysql"
                        }
                        ownerReferences = [
                            {
                                apiVersion = "aws.platform.upbound.io/v1alpha1"
                                blockOwnerDeletion = True
                                controller = True
                                kind = "SQLInstance"
                                name = "rds-metrics-database-ai-mysql"
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
                                    "networks.aws.platform.upbound.io/network-id" = "rds-metrics-database-ai-scale"
                                }
                            }
                        }
                    }
                }
            ]
            compositionPath: "apis/composition-rds-metrics.yaml"
            xrdPath: "apis/definition.yaml"
            xrPath: "examples/mariadb-xr-rds-metrics.yaml"
            functionCredentialsPath: "tests/test-credentials.yaml"
            timeoutSeconds: 60
            validate: False
        }
    }
    metav1alpha1.CompositionTest{
        metadata.name: "test-postgres"
        spec = {
            assertResources: [
                platformawsv1alpha1.SQLInstance{
                    metadata = {
                        name = "rds-metrics-database-ai-postgres"
                        namespace = "default"
                    }
                    spec = {
                        parameters = {
                            engine = "postgres"
                            engineVersion = "13.18"
                            networkRef = {
                                id = "rds-metrics-database-ai-scale"
                            }
                            passwordSecretRef = {
                                key = "password"
                                name = "psqlsecret"
                            }
                            region = "us-west-2"
                            storageGB = 5
                            instanceClass = "db.t3.micro"
                        }
                    }
                }
                rdsv1beta1.Instance{
                    metadata = {
                        annotations = {
                            "crossplane.io/composition-resource-name" = "rds-instance"
                        }
                        generateName = "rds-metrics-database-ai-postgres-"
                        labels = {
                            "crossplane.io/composite" = "rds-metrics-database-ai-postgres"
                        }
                        ownerReferences = [
                            {
                                apiVersion = "aws.platform.upbound.io/v1alpha1"
                                blockOwnerDeletion = True
                                controller = True
                                kind = "SQLInstance"
                                name = "rds-metrics-database-ai-postgres"
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
                            }
                            publiclyAccessible = False
                            region = "us-west-2"
                            skipFinalSnapshot = True
                            username = "masteruser"
                            vpcSecurityGroupIdSelector = {
                                matchLabels = {
                                    "networks.aws.platform.upbound.io/network-id": "rds-metrics-database-ai-scale"
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
                        generateName = "rds-metrics-database-ai-postgres-"
                        labels = {
                            "crossplane.io/composite" = "rds-metrics-database-ai-postgres"
                        }
                        ownerReferences = [
                            {
                                apiVersion = "aws.platform.upbound.io/v1alpha1"
                                blockOwnerDeletion = True
                                controller = True
                                kind = "SQLInstance"
                                name = "rds-metrics-database-ai-postgres"
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
                                    "networks.aws.platform.upbound.io/network-id": "rds-metrics-database-ai-scale"
                                }
                            }
                        }
                    }
                }
            ]
            compositionPath: "apis/composition-rds-metrics.yaml"
            xrdPath: "apis/definition.yaml"
            xrPath: "examples/postgres-xr-rds-metrics.yaml"
            functionCredentialsPath: "tests/test-credentials.yaml"
            timeoutSeconds: 60
            validate: False
        }
    }
]
items= _items
