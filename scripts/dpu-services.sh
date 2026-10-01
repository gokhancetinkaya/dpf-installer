#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

log "Phase: dpu-services"
require_cmds oc envsubst
require_cluster
require_vars \
  NUM_VFS BFB_URL BFB_ATF BFB_BSP BFB_DOCA BFB_UEFI \
  HOST_CLUSTER_API TARGETCLUSTER_API_SERVER_PORT \
  OVN_MTU OVN_POD_NETWORK OVN_SERVICE_NETWORK \
  VTEP_CIDR DPU_HOST_CIDR NODES_MTU

apply_manifest "$(manifest dpu-services/nodesriovdevicepluginconfig.yaml)"
oc get nodesriovdevicepluginconfig -n dpf-operator-system
apply_manifest "$(manifest "$(dpuflavor_manifest)")"
apply_manifest "$(manifest dpu-services/bfb.yaml)"
apply_manifest "$(manifest dpu-services/dpudeployment.yaml)"
apply_manifest "$(manifest dpu-services/hbn.yaml)"
apply_manifest "$(manifest dpu-services/ovn-k.yaml)"
apply_manifest "$(manifest dpu-services/dts.yaml)"
apply_manifest "$(manifest dpu-services/dpucredentialreq.yaml)"
apply_manifest "$(manifest dpu-services/physical-if.yaml)"
apply_manifest "$(manifest dpu-services/ovnk-if.yaml)"
apply_manifest "$(manifest dpu-services/dpuservice-nad.yaml)"
apply_manifest "$(manifest dpu-services/dpuservice-ipam.yaml)"

log "Waiting for DPU service IPAM and interfaces"
oc wait --for=condition=DPUIPAMObjectReconciled \
  --namespace dpf-operator-system dpuserviceipam --all \
  --timeout="${WAIT_CONDITIONS}s"
oc wait --for=condition=ServiceInterfaceSetReconciled \
  --namespace dpf-operator-system dpuserviceinterface --all \
  --timeout="${WAIT_CONDITIONS}s"
oc get dpuserviceconfiguration -n dpf-operator-system
log "DPU services configured"
