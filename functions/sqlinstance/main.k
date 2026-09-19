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

# Instance class tables, for turning raw CloudWatch bytes and counts into the
# percentages the scaling rules are actually written against.
#
# This exists because a real run scaled a database that needed nothing. The
# prompt's rule is "FreeableMemory under 15% of class memory", which silently
# requires the model to know that db.t3.micro is 1 GiB and then divide. It does
# not reliably know that: at 205 MiB free - 20.0% of a micro, comfortably above
# the threshold - it read the absolute number as low and scaled up. Computing
# the percentage here turns a recall-and-arithmetic problem into a comparison
# of two numbers. See tests/e2e-local/results/aws-cloud-run.md.
#
# Only the t3 classes this configuration progresses through are listed. An
# unknown class yields no percentage rather than a wrong one - the signal is
# omitted and the model falls back to the raw metric.
_classMemoryBytes = {
    "db.t3.micro" = 1073741824
    "db.t3.small" = 2147483648
    "db.t3.medium" = 4294967296
    "db.t3.large" = 8589934592
}

# MySQL and MariaDB default max_connections to {DBInstanceClassMemory/12582880}.
_classMaxConnections = {
    "db.t3.micro" = 85
    "db.t3.small" = 170
    "db.t3.medium" = 341
    "db.t3.large" = 683
}

# The progression, as two lookups rather than an ordered list plus index
# arithmetic: a missing key simply means there is no step in that direction,
# which is exactly the "no step left" gate.
_nextClass = {
    "db.t3.micro" = "db.t3.small"
    "db.t3.small" = "db.t3.medium"
    "db.t3.medium" = "db.t3.large"
}
_prevClass = {
    "db.t3.small" = "db.t3.micro"
    "db.t3.medium" = "db.t3.small"
    "db.t3.large" = "db.t3.medium"
}

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
    _observedClass = ocds["rds-instance"].Resource?.status?.atProvider?.instanceClass or ""
    # atProvider.status, not instanceStatus - the RDS Instance schema calls the
    # lifecycle field "status" ("The RDS instance status.").
    _observedStatus = ocds["rds-instance"].Resource?.status?.atProvider?.status or ""

    # The metrics are one reconcile behind: function-rds-metrics runs after this
    # step, so what is readable here is the previous pass's status. That is
    # immaterial - CloudWatch is on a 300s period, so the data is older than the
    # lag either way.
    # Reached by explicit membership tests, not "?.". oxr is an untyped dict
    # (see the note at the top), and "?." on a dict raises rather than yielding
    # Undefined when the key is absent - which is the normal state on a first
    # reconcile, before function-rds-metrics has ever written status.
    _xrStatus = oxr.status if "status" in oxr else {}
    _perf = _xrStatus.performanceMetrics if "performanceMetrics" in _xrStatus else {}
    _metrics = _perf.metrics if "metrics" in _perf else {}
    _classMem = _classMemoryBytes[_observedClass] or 0
    _maxConns = _classMaxConnections[_observedClass] or 0
    _freeMem = _metrics.FreeableMemory.value if "FreeableMemory" in _metrics else Undefined
    _conns = _metrics.DatabaseConnections.value if "DatabaseConnections" in _metrics else Undefined
    _cpu = _metrics.CPUUtilization.value if "CPUUtilization" in _metrics else Undefined

    _signals = {
        if _cpu != Undefined:
            cpuPercent = _cpu
        if _freeMem != Undefined and _classMem > 0:
            freeableMemoryPercent = round(_freeMem * 100.0 / _classMem, 1)
        if _conns != Undefined and _maxConns > 0:
            connectionsPercent = round(_conns * 100.0 / _maxConns, 1)
        if _classMem > 0:
            classMemoryBytes = _classMem
        if _maxConns > 0:
            classMaxConnections = _maxConns
    }

    # The deterministic answer, computed from the same rules the prompt states.
    #
    # Every one of those rules is arithmetic and string comparison: is the
    # resource settled, is a percentage over a line, does a step exist. None of
    # it needs a language model, and a real run proved a 1.5B gets it wrong in
    # the expensive direction. Publishing the answer here makes the model's
    # output checkable - compare it against this - and gives anything that wants
    # to enforce rather than suggest something to enforce.
    #
    # Nothing consumes this yet; the WatchOperation still applies the model's
    # patch. See tests/e2e-local/results/aws-cloud-run.md.
    _desiredClass = oxrParams.instanceClass or "db.t3.micro"
    _settled = _observedClass == _desiredClass and _observedStatus == "available"

    _cpuPct = _signals.cpuPercent if "cpuPercent" in _signals else Undefined
    _memPct = _signals.freeableMemoryPercent if "freeableMemoryPercent" in _signals else Undefined
    _connPct = _signals.connectionsPercent if "connectionsPercent" in _signals else Undefined

    # UP is any-of, so an absent percentage simply cannot contribute.
    _wantUp = (_cpuPct != Undefined and _cpuPct > 80) or \
              (_connPct != Undefined and _connPct > 80) or \
              (_memPct != Undefined and _memPct < 15)

    # DOWN is all-of, so an absent percentage makes it unprovable, not true.
    _wantDown = _cpuPct != Undefined and _connPct != Undefined and _memPct != Undefined and \
                _cpuPct < 20 and _connPct < 30 and _memPct > 60

    _recommended = _observedClass
    if _settled and _wantUp and _observedClass in _nextClass:
        _recommended = _nextClass[_observedClass]
    elif _settled and _wantDown and _observedClass in _prevClass:
        _recommended = _prevClass[_observedClass]

    _dxr.status = {
        observedInstanceClass = _observedClass
        observedInstanceStatus = _observedStatus
        if len(_signals) > 0:
            scalingSignals = _signals
        if _observedClass != "":
            recommendedInstanceClass = _recommended
    }

items = _items + [_dxr]
