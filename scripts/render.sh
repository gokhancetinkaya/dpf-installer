#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

require_cmds envsubst
require_install_vars
compute_sriov_vf_ranges
render_all
log "Rendered manifests in ${GENERATED_DIR}"
