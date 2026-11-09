#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

log "Phase: injector"
require_cmds oc helm
require_cluster

if is_zero_trust; then
  die "DPF_DEPLOYMENT_MODE=zero-trust does not deploy the OVN-Kubernetes DPU service, so the VF resource injector is a host-trusted-only operation."
fi

require_vars OVN_TEMPLATE_CHART_URL OVN_CHART_VERSION

helm_args=(
  -n openshift-ovn-kubernetes ovn-kubernetes
  "${OVN_TEMPLATE_CHART_URL}/ovn-kubernetes-chart"
  --version "$OVN_CHART_VERSION"
  --skip-crds
  --set ovn-kubernetes-resource-injector.enabled=true
  --set ovn-kubernetes-resource-injector.resourceName="openshift.io/bf3_vfs"
  --set ovn-kubernetes-resource-injector.prioritizeOffloading=false
  --set ovn-kubernetes-resource-injector.controllerManager.hostNetwork=true
  --set ovn-kubernetes-resource-injector.controllerManager.webhookPort="19443"
  --set ovn-kubernetes-resource-injector.controllerManager.healthProbeBindAddress=":18081"
  --set ovn-kubernetes-resource-injector.controllerManager.webhook.image.pullPolicy=IfNotPresent
  --set "ovn-kubernetes-resource-injector.controllerManager.webhook.args={--leader-elect,--metrics-bind-address=:29091}"
  --set nodeWithDPUManifests.enabled=false
  --set nodeWithoutDPUManifests.enabled=false
  --set dpuManifests.enabled=false
  --set controlPlaneManifests.enabled=false
  --set commonManifests.enabled=false
  --set-json 'ovn-kubernetes-resource-injector.runtimeClassMappings=[]'
)

if [[ "${KATA_ENABLED:-false}" == "true" ]]; then
  require_kata_vars
  log "KATA_ENABLED=true: adding runtime class mapping ${KATA_RUNTIME_CLASS} -> ${KATA_NAD_NAME} (${KATA_INJECTOR_RESOURCE_NAME})"
  helm_args+=(
    --set "ovn-kubernetes-resource-injector.runtimeClassMappings[0].runtimeClass=${KATA_RUNTIME_CLASS}"
    --set "ovn-kubernetes-resource-injector.runtimeClassMappings[0].nadName=${KATA_NAD_NAME}"
    --set "ovn-kubernetes-resource-injector.runtimeClassMappings[0].resourceName=${KATA_INJECTOR_RESOURCE_NAME}"
  )
fi

log "Installing OVN-Kubernetes resource injector ${OVN_CHART_VERSION}"
helm_upgrade "${helm_args[@]}" \
  --wait \
  --timeout "$HELM_TIMEOUT"

oc get mutatingwebhookconfiguration | grep ovn || die "OVN mutating webhook was not registered"
log "OVN-Kubernetes resource injector installed"
