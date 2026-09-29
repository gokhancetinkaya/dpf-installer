#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

log "Phase: observability"
require_cmds oc helm
require_cluster
require_vars GRAFANA_OPERATOR_CHART GRAFANA_OPERATOR_VERSION

apply_manifest "$(manifest observability/cluster-monitoring-config.yaml)"
log "Waiting up to ${WAIT_MEDIUM}s for user workload monitoring pods"
deadline=$((SECONDS + WAIT_MEDIUM))
while ((SECONDS < deadline)); do
  if oc get pods -n openshift-user-workload-monitoring --no-headers 2>/dev/null \
    | awk '$3 == "Running" { found = 1 } END { exit !found }'; then
    break
  fi
  sleep 10
done
oc -n openshift-user-workload-monitoring get pods || true

apply_manifest "$(manifest observability/dts-servicemonitor.yaml)"
apply_manifest "$(manifest observability/dts-console-dashboard.yaml)"

log "Installing grafana-operator ${GRAFANA_OPERATOR_VERSION}"
helm_upgrade grafana-operator "$GRAFANA_OPERATOR_CHART" \
  --version "$GRAFANA_OPERATOR_VERSION" \
  --namespace grafana-operator \
  --create-namespace \
  --wait \
  --timeout "$HELM_TIMEOUT"

apply_manifest "$(manifest observability/grafana-operator-route-rbac.yaml)"
apply_manifest "$(manifest observability/grafana-rbac.yaml)"
apply_manifest "$(manifest observability/grafana-cr.yaml)"
apply_manifest "$(manifest observability/grafana-datasource.yaml)"
apply_manifest "$(manifest observability/dts-grafana-dashboard.yaml)"

host=""
deadline=$((SECONDS + WAIT_SHORT))
while ((SECONDS < deadline)); do
  host="$(oc -n dpf-operator-system get route dpf-grafana-route -o jsonpath='{.spec.host}' 2>/dev/null || true)"
  if [[ -z "$host" ]]; then
    host="$(oc -n dpf-operator-system get route -o jsonpath='{range .items[*]}{.metadata.name}{" "}{.spec.host}{"\n"}{end}' 2>/dev/null | awk '/grafana/ { print $2; exit }' || true)"
  fi
  [[ -n "$host" ]] && break
  sleep 5
done
if [[ -n "$host" ]]; then
  log "Grafana URL: https://${host}"
else
  die "Grafana route dpf-grafana-route did not appear in dpf-operator-system"
fi
