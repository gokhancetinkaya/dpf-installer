#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

require_install_vars
scripts="$(dirname "${BASH_SOURCE[0]}")"
current_phase="preflight"
trap 'printf "ERROR: install failed during %s\n" "$current_phase" >&2' ERR

run_phase() {
  current_phase="$1"
  log ""
  "${scripts}/${current_phase}.sh"
}

run_phase preflight
run_phase platform
run_phase cluster-prep
run_phase dpf
run_phase dpu-services
run_phase hosted

if is_zero_trust; then
  current_phase="hosted-scc"
  log ""
  log "Zero Trust mode: applying the hosted-cluster privileged SCC binding for DPU services"
  "${scripts}/hosted-scc.sh"
  log ""
  log "Zero Trust mode: skipping injector and workers. DPUs are provisioned directly"
  log "over Redfish/OOB instead of joining as BareMetalHosts (see README.md)."
  wait_zero_trust_external_reboots
else
  run_phase injector
  run_phase workers
fi

log ""
log "DPF install complete."
log "Optional dashboards: make observability"
log "Current objects: make status"
