#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

require_cmds envsubst
require_install_vars
render_all
log "Rendered manifests in ${GENERATED_DIR}"
