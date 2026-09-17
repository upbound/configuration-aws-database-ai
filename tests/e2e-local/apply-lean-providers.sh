#!/usr/bin/env bash
# Scale Modelplane's unused cloud providers to zero, for real.
#
# tests/e2e-local/lean-providers.yaml declares the DeploymentRuntimeConfig and
# an ImageConfig that should bind it. Under `up project run` that is not enough:
# UXP sets an explicit `runtimeConfigRef: {name: default}` on every provider it
# installs, and an explicit ref on the Provider beats an ImageConfig-supplied
# runtime. Measured applying the ImageConfig both before and after the
# Configuration - all ten target providers stayed at ready=1/1 either way.
#
# So this patches each provider directly. It names them individually and never
# touches provider-aws-rds, provider-aws-ec2, provider-family-aws,
# provider-helm or provider-kubernetes - the five this configuration and
# Modelplane's BYO path actually use. Modelplane's own trim matches the prefix
# `provider-aws-`, which would catch the RDS provider and silently break the
# scaling demo.
#
# Safe to re-run. Modelplane's Configuration stays Healthy with these at zero;
# package health does not depend on pod readiness.
set -euo pipefail

DORMANT=(
  gcp-cloudplatform gcp-compute gcp-container
  azure-containerservice azure-network
  nebius vultr
  aws-eks aws-iam aws-efs
)

kubectl get deploymentruntimeconfig scale-to-zero >/dev/null 2>&1 || {
  echo "no 'scale-to-zero' DeploymentRuntimeConfig - apply lean-providers.yaml first" >&2
  exit 1
}

for p in "${DORMANT[@]}"; do
  if kubectl get provider.pkg.crossplane.io "upbound-provider-$p" >/dev/null 2>&1; then
    kubectl patch provider.pkg.crossplane.io "upbound-provider-$p" --type merge \
      -p '{"spec":{"runtimeConfigRef":{"apiVersion":"pkg.crossplane.io/v1beta1","kind":"DeploymentRuntimeConfig","name":"scale-to-zero"}}}' >/dev/null
    echo "  scaled to zero: $p"
  fi
done

echo
echo "waiting for the deployments to drain..."
until [ -z "$(kubectl -n crossplane-system get deploy --no-headers 2>/dev/null \
    | awk '/provider-(gcp|azure|nebius|vultr|aws-eks|aws-iam|aws-efs)/ && $2!="0/0"')" ]; do
  sleep 5
done

echo "dormant:"
kubectl -n crossplane-system get deploy --no-headers 2>/dev/null \
  | awk '/provider-(gcp|azure|nebius|vultr|aws-eks|aws-iam|aws-efs)/{print "  " $1 " " $2}'
echo "still active (must all be 1/1):"
kubectl -n crossplane-system get deploy --no-headers 2>/dev/null \
  | awk '/provider-(aws-rds|aws-ec2|family-aws|helm|kubernetes)/{print "  " $1 " " $2}'
