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
# @code-as-a-doc: start section "grafana-operator-install"
#   | remove-prefix: "helm_upgrade " | doc remove-prefix: "$ helm upgrade -i "
#   | TODO: "helm_upgrade is helm upgrade --install plus --force-conflicts (Helm 4) and --timeout; an asadoc option that maps a code command to the doc's would replace both remove-prefix options"
#   | TODO: "The docs use helm upgrade -i here and --install everywhere else; use --install in the docs"
#   | remove-lines-starting-with: "--wait"
#   | TODO: "The docs don't pass --wait, so the next step can run before the chart is ready; add --wait to the docs"
#   | reindent: 2 -> 4
#   | TODO: "The docs indent continuation lines by 4 here and by 2 in their maintenance-operator and injector commands; use 2 throughout the docs"
#   | param: "\"$*\""
helm_upgrade grafana-operator "$GRAFANA_OPERATOR_CHART" \
  --wait \
  --version "$GRAFANA_OPERATOR_VERSION" \
  --namespace grafana-operator \
  --create-namespace
# @code-as-a-doc: end section "grafana-operator-install"

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
