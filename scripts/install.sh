#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

require_install_vars
scripts="$(dirname "${BASH_SOURCE[0]}")"
current_phase="preflight"
trap 'printf "ERROR: install failed during %s\n" "$current_phase" >&2' ERR

ALL_PHASES=(preflight platform cluster-prep dpf dpu-services hosted hosted-scc injector workers)
declare -A SKIP_PHASE_SET=()
if [[ -n "${SKIP_PHASES:-}" ]]; then
  IFS=',' read -ra _skip_list <<< "${SKIP_PHASES}"
  for _phase in "${_skip_list[@]}"; do
    _phase="$(trim "$_phase")"
    [[ -n "$_phase" ]] || continue
    case " ${ALL_PHASES[*]} " in
      *" ${_phase} "*) ;;
      *) die "Unknown phase '${_phase}' in SKIP_PHASES (valid: ${ALL_PHASES[*]})" ;;
    esac
    SKIP_PHASE_SET[$_phase]=1
  done
fi

run_phase() {
  current_phase="$1"
  if [[ -n "${SKIP_PHASE_SET[$current_phase]:-}" ]]; then
    log ""
    log "Skipping ${current_phase} (SKIP_PHASES)"
    return 0
  fi
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
  if [[ -n "${SKIP_PHASE_SET[hosted-scc]:-}" ]]; then
    current_phase="hosted-scc"
    log ""
    log "Skipping hosted-scc (SKIP_PHASES)"
  else
    current_phase="hosted-scc"
    log ""
    log "Zero Trust mode: applying the hosted-cluster privileged SCC binding for DPU services"
    "${scripts}/hosted-scc.sh"
    log ""
    log "Zero Trust mode: skipping injector and workers. DPUs are provisioned directly"
    log "over Redfish/OOB instead of joining as BareMetalHosts (see README.md)."
    wait_zero_trust_external_reboots
  fi
else
  run_phase injector
  run_phase workers
fi

log ""
log "DPF install complete."
log "Optional dashboards: make observability"
log "Current objects: make status"
