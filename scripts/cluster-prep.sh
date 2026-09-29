#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

log "Phase: cluster-prep"
require_cmds oc envsubst
require_cluster
require_vars HOST_CLUSTER_API TARGETCLUSTER_API_SERVER_PORT

apply_manifest "$(manifest cluster-prep/nfd-instance.yaml)"
apply_manifest "$(manifest cluster-prep/nfd-rule.yaml)"
apply_manifest "$(manifest cluster-prep/metallb-config.yaml)"
apply_manifest "$(manifest cluster-prep/argocd-instance.yaml)"
wait_rollout dpf-operator-system argocd-redis "$WAIT_MEDIUM"

log "Enabling global IP forwarding on the OVN-Kubernetes network"
oc patch network.operator.openshift.io cluster --type=merge --patch \
  '{"spec":{"defaultNetwork":{"ovnKubernetesConfig":{"gatewayConfig":{"ipForwarding":"Global"}}}}}'
oc get network.operator cluster -o jsonpath='{.spec.defaultNetwork.ovnKubernetesConfig.gatewayConfig.ipForwarding}{"\n"}'
log "Cluster prep complete"
