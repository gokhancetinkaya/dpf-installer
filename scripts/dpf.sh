#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

log "Phase: dpf"
require_cmds oc helm envsubst
require_cluster
require_vars \
  DPF_HELM_REPO DPF_VERSION \
  HOST_CLUSTER_API NODES_MTU TARGETCLUSTER_API_SERVER_PORT FLANNEL_POD_CIDR

log "Installing dpf-operator ${DPF_VERSION}"
helm repo add --force-update dpf-repository "$DPF_HELM_REPO"
helm repo update dpf-repository
# @code-as-a-doc: start section "dpf-operator-install"
#   | remove-prefix: "helm_upgrade " | doc remove-prefix: "$ helm upgrade --install "
#   | TODO: "helm_upgrade is helm upgrade --install plus --force-conflicts (Helm 4) and --timeout; an asadoc option that maps a code command to the doc's would replace both remove-prefix options"
#   | reindent: 2 -> 4
#   | TODO: "The docs indent continuation lines by 4 here and by 2 in their maintenance-operator and injector commands; use 2 throughout the docs"
#   | param: "\"$*\""
helm_upgrade dpf-operator dpf-repository/dpf-operator \
  --namespace dpf-operator-system \
  --version "$DPF_VERSION" \
  --set kamajiEtcdDefrag.enabled=false \
  --set isOpenshift=true \
  --set enableNodeFeatureRules=false \
  --wait
# @code-as-a-doc: end section "dpf-operator-install"

wait_rollout dpf-operator-system dpf-operator-controller-manager "$WAIT_MEDIUM"
apply_manifest "$(manifest dpf/dpfoperatorconfig.yaml)"
wait_rollout dpf-operator-system dpf-provisioning-controller-manager "$WAIT_MEDIUM"
wait_rollout dpf-operator-system dpuservice-controller-manager "$WAIT_MEDIUM"
oc get pods -n dpf-operator-system
log "DPF operator configured"
