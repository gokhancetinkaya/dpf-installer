#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

log "Phase: external-reboot"
require_common
is_zero_trust || die "make external-reboot only applies to DPF_DEPLOYMENT_MODE=zero-trust"
require_zero_trust

wait_zero_trust_external_reboots --force
