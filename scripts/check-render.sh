#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

script_dir="$(dirname "${BASH_SOURCE[0]}")"
shopt -s nullglob
for script in "$script_dir"/*.sh; do
  bash -n "$script"
done
bash -n "$script_dir/lib.sh"

require_cmds envsubst
require_install_vars
render_all

flavor="${GENERATED_DIR}/dpu-services/dpuflavor.yaml"
grep -F -q "NUM_OF_VFS=${NUM_VFS}" "$flavor" || die "DPUFlavor NUM_VFS was not rendered"
grep -F -q 'other_config:$1' "$flavor" || die "DPUFlavor shell script lost \$1"
grep -F -q '"$@"' "$flavor" || die "DPUFlavor shell script lost \$@"
if grep -F -q 'NUM_OF_VFS=${NUM_VFS}' "$flavor"; then
  die "DPUFlavor still contains an unsubstituted NUM_VFS"
fi

ovn="${GENERATED_DIR}/dpu-services/ovn-k.yaml"
grep -F -q "https://${HOST_CLUSTER_API}:${TARGETCLUSTER_API_SERVER_PORT}" "$ovn" || die "OVN API server was not rendered"
grep -F -q "vtepCIDR: ${VTEP_CIDR}" "$ovn" || die "OVN VTEP CIDR was not rendered"
grep -F -q "hostCIDR: ${DPU_HOST_CIDR}" "$ovn" || die "OVN host CIDR was not rendered"
grep -F -q "mtu: ${OVN_MTU}" "$ovn" || die "OVN MTU was not rendered"
grep -F -q "podNetwork: ${OVN_POD_NETWORK}" "$ovn" || die "OVN pod network was not rendered"

provisioner="${GENERATED_DIR}/hosted/dpfhcpprovisioner.yaml"
grep -F -q "name: ${HOSTED_CLUSTER_NAME}" "$provisioner" || die "Hosted cluster name was not rendered"
grep -F -q "ocpReleaseImage: ${OCP_RELEASE_IMAGE}" "$provisioner" || die "OCP release image was not rendered"
grep -F -q "virtualIP: ${HOSTED_CLUSTER_VIP}" "$provisioner" || die "Hosted cluster VIP was not rendered"

bmc="${GENERATED_DIR}/workers/bmc-secret.yaml"
grep -F -q "username: ${BMC_USER}" "$bmc" || die "BMC username was not rendered"
grep -F -q "password: ${BMC_PASSWORD}" "$bmc" || die "BMC password was not rendered"
if grep -F -q 'password: ${BMC_PASSWORD}' "$bmc"; then
  die "BMC secret still contains an unsubstituted password"
fi

gitops="${GENERATED_DIR}/platform/gitops-operator.yaml"
grep -F -q "channel: ${GITOPS_OPERATOR_CHANNEL}" "$gitops" || die "GitOps channel was not rendered"
grep -F -q "startingCSV: ${GITOPS_OPERATOR_CSV}" "$gitops" || die "GitOps CSV was not rendered"

hbn_src="$(manifest dpu-services/hbn.yaml)"
hbn_out="${GENERATED_DIR}/dpu-services/hbn.yaml"
cmp -s "$hbn_src" "$hbn_out" || die "HBN manifest was modified during render"
grep -q '{{ ipaddresses.ip_lo.ip }}' "$hbn_out" || die "HBN Jinja template was stripped"

grafana_src="$(manifest observability/grafana-datasource.yaml)"
grafana_out="${GENERATED_DIR}/observability/grafana-datasource.yaml"
cmp -s "$grafana_src" "$grafana_out" || die "Grafana datasource was modified during render"
grep -q 'Bearer ${token}' "$grafana_out" || die "Grafana datasource token placeholder was removed"

dashboard_src="$(manifest observability/dts-grafana-dashboard.yaml)"
dashboard_out="${GENERATED_DIR}/observability/dts-grafana-dashboard.yaml"
cmp -s "$dashboard_src" "$dashboard_out" || die "Grafana dashboard was modified during render"

while IFS= read -r -d '' src; do
  rel="${src#"${MANIFESTS_DIR}/"}"
  if is_template "$src"; then
    if grep -E '\$\{[A-Z][A-Z0-9_]+\}' "${GENERATED_DIR}/${rel}" >/dev/null; then
      die "Unsubstituted variable in ${rel}"
    fi
  else
    cmp -s "$src" "${GENERATED_DIR}/${rel}" || die "Static manifest changed during render: ${rel}"
  fi
done < <(find "$MANIFESTS_DIR" -type f -name '*.yaml' -print0)

log "Render check passed"
