#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

log "Phase: preflight"
require_cmds oc helm envsubst
require_common

export KUBECONFIG
oc whoami >/dev/null || die "oc cannot authenticate with KUBECONFIG=${KUBECONFIG}"
log "Cluster nodes:"
oc get nodes

oc get crd nodefeaturediscoveries.nfd.openshift.io >/dev/null \
  || die "NodeFeatureDiscovery CRD not found. The NFD operator must already be installed on the management cluster."
oc get ns openshift-machine-api >/dev/null \
  || die "Namespace openshift-machine-api not found. This install expects a bare-metal management cluster."
check_hypershift
require_version_skew
# Best-effort hardware check: on re-runs where the worker node already joined
# and DPF discovery ran, fail here instead of mid-install. Fresh installs
# have no DPUDevices at preflight; the workers phase enforces the same check
# once discovery runs.
validate_dpu_hardware
# Pre-install hardware check through each configured worker's BMC (Redfish):
# fails before anything is installed when a host has more than one
# BlueField-3 or a non-dual-port one. Skipped for hosts whose BMC does not
# expose the inventories; the workers phase remains the backstop.
if ! is_zero_trust && (( ${WORKER_COUNT:-0} > 0 )); then
  _wi=1
  while (( _wi <= WORKER_COUNT )); do
    if (( _wi == 1 )); then
      _bmc_ip="${BMC_IP:-}"
      _bmc_user="${BMC_USER:-}"
      _bmc_password="${BMC_PASSWORD:-}"
    else
      _v="WORKER_${_wi}_BMC_IP"; _bmc_ip="${!_v:-}"
      _v="WORKER_${_wi}_BMC_USER"; _bmc_user="${!_v:-}"
      _v="WORKER_${_wi}_BMC_PASSWORD"; _bmc_password="${!_v:-}"
    fi
    if [[ -n "${_bmc_ip:-}" && -n "${_bmc_user:-}" && -n "${_bmc_password:-}" ]]; then
      check_dpu_hardware_bmc "$_bmc_ip" "$_bmc_user" "$_bmc_password"
    fi
    _wi=$((_wi + 1))
  done
fi

if is_zero_trust; then
  log "DPF_DEPLOYMENT_MODE=zero-trust: validating Zero Trust configuration"
  require_zero_trust
  check_zero_trust_bmc_reachability
fi

log "Preflight ok"
