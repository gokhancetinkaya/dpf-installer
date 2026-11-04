#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

log "Phase: dpf"
require_cmds oc helm envsubst
require_cluster
require_vars \
  DPF_HELM_REPO DPF_VERSION \
  HOST_CLUSTER_API NODES_MTU TARGETCLUSTER_API_SERVER_PORT FLANNEL_POD_CIDR

if is_zero_trust; then
  require_zero_trust
  power_on_zero_trust_hosts
fi

log "Installing dpf-operator ${DPF_VERSION}"
helm repo add --force-update dpf-repository "$DPF_HELM_REPO"
helm repo update dpf-repository
helm_upgrade dpf-operator dpf-repository/dpf-operator \
  --namespace dpf-operator-system \
  --version "$DPF_VERSION" \
  --set kamajiEtcdDefrag.enabled=false \
  --set isOpenshift=true \
  --set enableNodeFeatureRules=false \
  --wait \
  --timeout "$HELM_TIMEOUT"

wait_rollout dpf-operator-system dpf-operator-controller-manager "$WAIT_MEDIUM"

if is_zero_trust; then
  log "Zero Trust mode: granting the privileged SCC to the DPF default service account"
  oc adm policy add-scc-to-user privileged -z default -n dpf-operator-system

  apply_manifest "$(manifest dpf/zero-trust/bmc-shared-password.yaml)"

  apply_zero_trust_bootstrap_auth

  export SKIP_DPU_NODE_DISCOVERY=false
  [[ "$ZT_DPU_DISCOVERY_MODE" == "static" ]] && SKIP_DPU_NODE_DISCOVERY=true
fi

apply_manifest "$(manifest "$(dpfoperatorconfig_manifest)")"
wait_rollout dpf-operator-system dpf-provisioning-controller-manager "$WAIT_MEDIUM"
wait_rollout dpf-operator-system dpuservice-controller-manager "$WAIT_MEDIUM"
oc get pods -n dpf-operator-system

if is_zero_trust; then
  configure_zero_trust_bfb_registry
  configure_zero_trust_dpu_inventory
fi

log "DPF operator configured"
