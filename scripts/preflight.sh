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
log "Preflight ok"
