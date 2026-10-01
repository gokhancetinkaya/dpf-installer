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
# @code-as-a-doc: start section "dpu-worker-config-install"
#   | remove-prefix: "helm_upgrade " | doc remove-prefix: "$ helm upgrade --install "
#   | TODO: "helm_upgrade is helm upgrade --install plus --force-conflicts (Helm 4) and --timeout; an asadoc option that maps a code command to the doc's would replace both remove-prefix options"
#   | remove-lines-starting-with: "--wait"
#   | TODO: "The docs don't pass --wait, so the next step can run before the chart is ready; add --wait to the docs"
#   | reindent: 2 -> 4
#   | TODO: "The docs indent continuation lines by 4 here and by 2 in their maintenance-operator and injector commands; use 2 throughout the docs"
#   | param: "\"$*\""
helm_upgrade dpu-worker-config \
  "$DPU_WORKER_CONFIG_CHART" \
  --wait \
  --version "$DPU_WORKER_CONFIG_VERSION" \
  --registry-config "$OPENSHIFT_PULL_SECRET" \
  --namespace dpf-hcp-provisioner-system \
  --create-namespace \
  --disable-openapi-validation
# @code-as-a-doc: end section "dpu-worker-config-install"

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
values_file="$(manifest platform/maintenance-operator-values.yaml)"
# @code-as-a-doc: start section "maintenance-operator-install"
#   | remove-prefix: "helm_upgrade " | doc remove-prefix: "$ helm upgrade --install "
#   | TODO: "helm_upgrade is helm upgrade --install plus --force-conflicts (Helm 4) and --timeout; an asadoc option that maps a code command to the doc's would replace both remove-prefix options"
#   | param: "\"$*\""
helm_upgrade maintenance-operator "$MAINTENANCE_OPERATOR_CHART" \
  --namespace dpf-operator-system \
  --create-namespace \
  --disable-openapi-validation \
  --version "$MAINTENANCE_OPERATOR_VERSION" \
  --values "$values_file" \
  --wait
# @code-as-a-doc: end section "maintenance-operator-install"

oc get pods -n dpf-operator-system
log "Platform operators installed"
