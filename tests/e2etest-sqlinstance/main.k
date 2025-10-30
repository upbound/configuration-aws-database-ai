import models.io.upbound.awsm.v1beta1 as awsv1beta1
import models.io.upbound.dev.meta.v1alpha1 as metav1alpha1
import models.io.upbound.platform.aws.v1alpha1 as platformawsv1alpha1

_items = [
    metav1alpha1.E2ETest{
        metadata.name: "sqlinstances"
        spec= {
            crossplane.autoUpgrade.channel: "Rapid"
            defaultConditions: ["Ready"]
            manifests: [
                platformawsv1alpha1.SQLInstance{
                    metadata = {
                        name = "configuration-aws-database-mariadb"
                    }
                    spec = {
                        parameters = {
                            region = "us-west-2"
                            engine = "mariadb"
                            engineVersion = "10.11"
                            storageGB = 5
                            autoGeneratePassword = True
                            passwordSecretRef = {
                                name = "mariadbsecret"
                                key = "password"
                            }
                            networkRef = {
                                id = "configuration-aws-database"
                            }
                        }
                    }
                }
                platformawsv1alpha1.SQLInstance{
                    metadata = {
                        name = "configuration-aws-database-postgres"
                    }
                    spec = {
                        parameters = {
                            region = "us-west-2"
                            engine = "postgres"
                            engineVersion = "13.18"
                            storageGB = 5
                            autoGeneratePassword = True
                            passwordSecretRef = {
                                name = "psqlsecret"
                                key = "password"
                            }
                            networkRef = {
                                id = "configuration-aws-database"
                            }
                        }
                    }
                }
                platformawsv1alpha1.XNetwork{
                    apiVersion = "aws.platform.upbound.io/v1alpha1"
                    kind = "XNetwork"
                    metadata = {
                        name = "configuration-aws-database"
                    }
                    spec = {
                        parameters = {
                            id = "configuration-aws-database"
                            region = "us-west-2"
                        }
                    }
                }

            ]
            extraResources: [
                # Define the provider configuration
                awsv1beta1.ProviderConfig{
                    metadata.name = "default"
                    spec = {
                        credentials = {
                            source = "Upbound"
                            upbound = {
                                webIdentity = {
                                    roleARN = "arn:aws:iam::609897127049:role/solutions-e2e-provider-aws"
                                }
                            }
                        }
                    }
                }
            ]
            skipDelete: False
            timeoutSeconds: 4500
        }
    }
]
items= _items
