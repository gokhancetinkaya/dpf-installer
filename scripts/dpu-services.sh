#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

log "Phase: dpu-services"
require_cmds oc envsubst
require_cluster

if is_zero_trust; then
  require_zero_trust
  power_on_zero_trust_hosts
  require_vars NUM_VFS BFB_URL \
    HBN_HELM_REPO_URL HBN_HELM_CHART_VERSION HBN_IMAGE_REPO HBN_IMAGE_TAG \
    ZT_HBN_POOL1_CIDR ZT_HBN_POOL2_CIDR ZT_HBN_LOOPBACK_CIDR

  apply_manifest "$(manifest "$(dpuflavor_manifest)")"
  apply_manifest "$(manifest dpu-services/bfb.yaml)"

  log "Waiting up to ${WAIT_MEDIUM}s for BFB bf-bundle to become Ready"
  bfb_deadline=$((SECONDS + WAIT_MEDIUM))
  while true; do
    if [[ "$(oc get bfb bf-bundle -n dpf-operator-system -o jsonpath='{.status.phase}' 2>/dev/null)" == "Ready" ]]; then
      break
    fi
    if ((SECONDS >= bfb_deadline)); then
      oc get bfb bf-bundle -n dpf-operator-system -o yaml || true
      die "Timed out waiting for BFB bf-bundle to become Ready"
    fi
    sleep 10
  done

  # dpf-hcp-provisioner-operator runs with manageDPUServiceTemplates=false in
  # Zero Trust mode (scripts/hosted.sh), so this installer supplies its own
  # DPUServiceTemplate for HBN.
  apply_manifest "$(manifest dpu-services/zero-trust/dpuservicetemplate.yaml)"

  export DPU_VALUES
  DPU_VALUES="$(build_zero_trust_dpu_values)"
  [[ -n "$DPU_VALUES" ]] || die "No DPU serials configured (set DPU1_SERIAL in .env)"
  apply_manifest "$(manifest dpu-services/zero-trust/hbn-configuration.yaml)"

  apply_manifest "$(manifest dpu-services/zero-trust/dpuserviceinterface.yaml)"
  apply_manifest "$(manifest dpu-services/zero-trust/dpuservice-ipam.yaml)"
  apply_manifest "$(manifest dpu-services/zero-trust/dpuservice-nad.yaml)"
  # Refresh the registry address after the BFB is Ready and before a DPU is created.
  configure_zero_trust_bfb_registry
  apply_manifest "$(manifest dpu-services/zero-trust/dpudeployment.yaml)"

  log "Waiting for DPU service IPAM, interfaces, and service chains"
  oc wait --for=condition=DPUIPAMObjectReconciled \
    --namespace dpf-operator-system dpuserviceipam --all \
    --timeout="${WAIT_CONDITIONS}s"
  oc wait --for=condition=ServiceInterfaceSetReconciled \
    --namespace dpf-operator-system dpuserviceinterface --all \
    --timeout="${WAIT_CONDITIONS}s"
  oc wait --for=condition=ServiceChainSetReconciled \
    --namespace dpf-operator-system dpuservicechain --all \
    --timeout="${WAIT_CONDITIONS}s"
  oc get dpuserviceconfiguration -n dpf-operator-system

  log "DPU services configured (Zero Trust)"
  log "The hosted-cluster privileged SCC binding runs after 'make hosted' (see 'make install')."
  exit 0
fi

require_vars \
  NUM_VFS BFB_URL BFB_ATF BFB_BSP BFB_DOCA BFB_UEFI \
  HOST_CLUSTER_API TARGETCLUSTER_API_SERVER_PORT \
  OVN_MTU OVN_POD_NETWORK OVN_SERVICE_NETWORK \
  VTEP_CIDR DPU_HOST_CIDR NODES_MTU

if [[ "${KATA_ENABLED:-false}" == "true" ]]; then
  require_kata_vars
fi
compute_sriov_vf_ranges
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
