#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

log "Phase: hosted-scc"
require_cmds oc
require_cluster
require_vars HOSTED_CLUSTER_NAME CLUSTERS_NAMESPACE

hosted_kubeconfig="${ROOT}/generated/${HOSTED_CLUSTER_NAME}.kubeconfig"
mkdir -p "${ROOT}/generated"
chmod 700 "${ROOT}/generated"

secret_ns=""
for ns in "$CLUSTERS_NAMESPACE" dpf-operator-system; do
  if oc get secret "${HOSTED_CLUSTER_NAME}-admin-kubeconfig" -n "$ns" >/dev/null 2>&1; then
    secret_ns="$ns"
    break
  fi
done
[[ -n "$secret_ns" ]] || die "Secret ${HOSTED_CLUSTER_NAME}-admin-kubeconfig was not found in ${CLUSTERS_NAMESPACE} or dpf-operator-system"

oc get secret "${HOSTED_CLUSTER_NAME}-admin-kubeconfig" -n "$secret_ns" \
  -o jsonpath='{.data.kubeconfig}' | base64 -d >"$hosted_kubeconfig"
chmod 600 "$hosted_kubeconfig"
[[ -s "$hosted_kubeconfig" ]] || die "Secret ${HOSTED_CLUSTER_NAME}-admin-kubeconfig in ${secret_ns} has no kubeconfig data"
grep -q 'apiVersion:' "$hosted_kubeconfig" || die "Secret ${HOSTED_CLUSTER_NAME}-admin-kubeconfig in ${secret_ns} did not contain a kubeconfig"
log "Wrote hosted kubeconfig from secret in ${secret_ns}"

(
  export KUBECONFIG="$hosted_kubeconfig"
  oc apply -f "$(manifest hosted-scc/dpu-cluster-scc.yaml)"
)
log "Applied privileged SCC binding on the hosted cluster"
