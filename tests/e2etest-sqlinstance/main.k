import models.io.upbound.awsm.v1beta1 as awsv1beta1
import models.io.upbound.dev.meta.v1alpha1 as metav1alpha1
import models.io.upbound.platform.aws.v1alpha1 as platformawsv1alpha1
import models.io.k8s.api.core.v1 as corev1

_items = [
    metav1alpha1.E2ETest{
        metadata.name: "sqlinstances"
        spec= {
            crossplane.autoUpgrade.channel: "None"
            crossplane.version: "2.1.1-up.1"
            defaultConditions: ["Ready"]
            manifests: [
                # MariaDB instance with AI-powered scaling enabled
                platformawsv1alpha1.SQLInstance{
                    metadata = {
                        name = "configuration-aws-database-ai-e2e-mariadb"
                        namespace = "default"
                        labels = {
                            "scale" = "me"
                        }
                    }
                    spec = {
                        crossplane.compositionSelector.matchLabels = {
                            "type" = "rds-metrics"
                        }
                        parameters = {
                            region = "us-west-2"
                            engine = "mariadb"
                            engineVersion = "10.11"
                            storageGB = 5
                            instanceClass = "db.t3.micro"
                            autoGeneratePassword = True
                            publiclyAccessible = False
                            passwordSecretRef = {
                                name = "mariadbsecret"
                                key = "password"
                            }
                            networkRef = {
                                id = "configuration-aws-database-ai-e2e"
                            }
                        }
                    }
                }
                # Postgres instance without AI scaling (baseline test)
                platformawsv1alpha1.SQLInstance{
                    metadata = {
                        name = "configuration-aws-database-ai-e2e-postgres"
                        namespace = "default"
                    }
                    spec = {
                        crossplane.compositionSelector.matchLabels = {
                            "type" = "rds-metrics"
                        }
                        parameters = {
                            region = "us-west-2"
                            engine = "postgres"
                            engineVersion = "13.18"
                            storageGB = 5
                            instanceClass = "db.t3.micro"
                            autoGeneratePassword = True
                            publiclyAccessible = False
                            passwordSecretRef = {
                                name = "psqlsecret"
                                key = "password"
                            }
                            networkRef = {
                                id = "configuration-aws-database-ai-e2e"
                            }
                        }
                    }
                }
                platformawsv1alpha1.Network{
                    apiVersion = "aws.platform.upbound.io/v1alpha1"
                    kind = "Network"
                    metadata = {
                        name = "configuration-aws-database-ai-e2e"
                        namespace = "default"
                    }
                    spec = {
                        parameters = {
                            id = "configuration-aws-database-ai-e2e"
                            region = "us-west-2"
                        }
                    }
                }

            ]
            extraResources: [
                # Define the provider configuration
                awsv1beta1.ProviderConfig{
                    metadata = {
                        name = "default"
                        namespace = "default"
                    }
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
                # AWS credentials secret for function-rds-metrics (fake credentials for e2e test)
                corev1.Secret{
                    metadata = {
                        name = "aws-creds"
                        namespace = "crossplane-system"
                    }
                    type = "Opaque"
                    data = {
                        credentials = "W2RlZmF1bHRdCmF3c19hY2Nlc3Nfa2V5X2lkID0gQUtJQUlPU0ZPRE5ON0VYQU1QTEUKYXdzX3NlY3JldF9hY2Nlc3Nfa2V5ID0gd0phbHJYVXRuRkVNSS9LN01ERU5HL2JQeFJmaUNZRVhBTVBMRUtFWQ=="
                    }
                }
            ]
            skipDelete: False
            timeoutSeconds: 4500
        }
    }
]
items= _items
