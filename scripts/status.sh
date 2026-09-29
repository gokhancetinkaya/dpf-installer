#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

require_cmds oc
require_cluster

show() {
  log "$1"
  shift
  "$@" || true
  printf '\n'
}

show "Nodes" oc get nodes
show "MachineConfigPool worker-dpu" oc get mcp worker-dpu
show "DPF operator pods" oc get pods -n dpf-operator-system
show "DPUs" oc get dpu -n dpf-operator-system
show "DPU services" oc get dpuservices -n dpf-operator-system
show "Hosted provisioner" oc get dpfhcpprovisioner -n "$CLUSTERS_NAMESPACE"
show "BareMetalHosts" oc get bmh -n openshift-machine-api

if oc get deploy/dpf-operator-controller-manager -n dpf-operator-system >/dev/null 2>&1; then
  show "dpfctl dpudeployments" \
    oc -n dpf-operator-system exec deploy/dpf-operator-controller-manager -- /dpfctl describe dpudeployments
fi
