#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

log "Phase: platform"
require_cmds oc helm envsubst
require_cluster
require_vars \
  OPENSHIFT_PULL_SECRET \
  DPU_WORKER_CONFIG_CHART DPU_WORKER_CONFIG_VERSION \
  MAINTENANCE_OPERATOR_CHART MAINTENANCE_OPERATOR_VERSION \
  GITOPS_OPERATOR_CHANNEL GITOPS_OPERATOR_CSV

log "Installing dpu-worker-config ${DPU_WORKER_CONFIG_VERSION}"
helm_upgrade dpu-worker-config \
  "$DPU_WORKER_CONFIG_CHART" \
  --version "$DPU_WORKER_CONFIG_VERSION" \
  --registry-config "$OPENSHIFT_PULL_SECRET" \
  --namespace dpf-hcp-provisioner-system \
  --create-namespace \
  --disable-openapi-validation \
  --wait \
  --timeout "$HELM_TIMEOUT"

oc get mcp worker-dpu || log "worker-dpu MachineConfigPool is not listed yet"
oc get machineconfig dpu-worker-configuration || log "dpu-worker-configuration MachineConfig is not listed yet"

oc apply -f - <<'EOF'
apiVersion: v1
kind: Namespace
metadata:
  name: dpf-operator-system
EOF

apply_manifest "$(manifest platform/cert-manager-operator.yaml)"
wait_pods_match cert-manager cert-manager "$WAIT_MEDIUM"

apply_manifest "$(manifest platform/metallb-operator.yaml)"
wait_pods_match openshift-operators metallb-operator "$WAIT_MEDIUM"

apply_manifest "$(manifest platform/gitops-operator.yaml)"
wait_pods_match openshift-gitops-operator openshift-gitops-operator "$WAIT_MEDIUM"

log "Installing maintenance-operator ${MAINTENANCE_OPERATOR_VERSION}"
helm_upgrade maintenance-operator "$MAINTENANCE_OPERATOR_CHART" \
  --namespace dpf-operator-system \
  --create-namespace \
  --disable-openapi-validation \
  --version "$MAINTENANCE_OPERATOR_VERSION" \
  --values "$(manifest platform/maintenance-operator-values.yaml)" \
  --wait \
  --timeout "$HELM_TIMEOUT"

oc get pods -n dpf-operator-system
log "Platform operators installed"
