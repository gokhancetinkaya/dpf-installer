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
run_phase injector
run_phase workers

log ""
log "DPF install complete."
log "Optional dashboards: make observability"
log "Current objects: make status"
