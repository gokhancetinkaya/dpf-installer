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
# Zero Trust manifests always render below (render_all walks the whole
# manifest tree) and this script reads these values directly, regardless of
# the current DPF_DEPLOYMENT_MODE.
require_vars ZT_BFB_REGISTRY_PORT ZT_CONTROL_PLANE_MTU \
  HBN_HELM_CHART_VERSION HBN_IMAGE_TAG \
  ZT_HBN_POOL1_CIDR ZT_HBN_POOL2_CIDR ZT_HBN_LOOPBACK_CIDR
render_all

for flavor_name in dpuflavor-9000.yaml dpuflavor-1500.yaml; do
  flavor="${GENERATED_DIR}/dpu-services/${flavor_name}"
  grep -F -q "NUM_OF_VFS=${NUM_VFS}" "$flavor" || die "DPUFlavor NUM_VFS was not rendered in ${flavor_name}"
  grep -F -q 'other_config:$1' "$flavor" || die "DPUFlavor shell script lost \$1 in ${flavor_name}"
  grep -F -q '"$@"' "$flavor" || die "DPUFlavor shell script lost \$@ in ${flavor_name}"
  if grep -F -q 'NUM_OF_VFS=${NUM_VFS}' "$flavor"; then
    die "DPUFlavor still contains an unsubstituted NUM_VFS in ${flavor_name}"
  fi
done

jumbo="${GENERATED_DIR}/dpu-services/dpuflavor-9000.yaml"
standard="${GENERATED_DIR}/dpu-services/dpuflavor-1500.yaml"
grep -F -q 'NUM_VF_MSIX=30' "$jumbo" || die "9000 DPUFlavor is missing NUM_VF_MSIX"
grep -F -q 'set Interface br-dpu mtu_request=9000' "$jumbo" || die "9000 DPUFlavor is missing br-dpu MTU"
grep -F -q 'set Interface br-ovn mtu_request=9000' "$jumbo" || die "9000 DPUFlavor is missing br-ovn MTU"
if grep -F -q 'NUM_VF_MSIX' "$standard"; then
  die "1500 DPUFlavor sets NUM_VF_MSIX"
fi
if grep -F -q 'mtu_request=9000' "$standard"; then
  die "1500 DPUFlavor requests MTU 9000"
fi
selected="${GENERATED_DIR}/$(dpuflavor_manifest)"
[[ -f "$selected" ]] || die "Selected DPUFlavor was not rendered"

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

# Zero Trust manifests always render (render_all walks the whole tree), so
# these checks run regardless of the current DPF_DEPLOYMENT_MODE.
zt_dpfconfig="${GENERATED_DIR}/dpf/zero-trust/dpfoperatorconfig.yaml"
grep -F -q 'installViaRedfish:' "$zt_dpfconfig" || die "Zero Trust DPFOperatorConfig is missing installViaRedfish"
if grep -E -q 'bfbRegistryAddress:|bfbRegistry:' "$zt_dpfconfig"; then
  die "Zero Trust DPFOperatorConfig still sets the deprecated bfbRegistry address"
fi
zt_registry="${GENERATED_DIR}/dpf/zero-trust/bfb-registry-nodeport.yaml"
grep -F -q "nodePort: ${ZT_BFB_REGISTRY_PORT}" "$zt_registry" || die "Zero Trust BFB registry NodePort was not rendered"
grep -F -q "controlPlaneMTU: ${ZT_CONTROL_PLANE_MTU}" "$zt_dpfconfig" || die "Zero Trust DPFOperatorConfig controlPlaneMTU was not rendered"
grep -F -q "highSpeedMTU: ${NODES_MTU}" "$zt_dpfconfig" || die "Zero Trust DPFOperatorConfig highSpeedMTU was not rendered"
if [[ "$ZT_CONTROL_PLANE_MTU" -gt 1500 ]]; then
  die "ZT_CONTROL_PLANE_MTU exceeds NVIDIA's Zero Trust cap of 1500"
fi
if grep -E '\$\{[A-Z][A-Z0-9_]+\}' "$zt_dpfconfig" >/dev/null; then
  die "Zero Trust DPFOperatorConfig has an unsubstituted variable"
fi

if [[ -n "${ZT_DPU_BMC_ROOT_PASSWORD:-}" ]]; then
  zt_bmc_secret="${GENERATED_DIR}/dpf/zero-trust/bmc-shared-password.yaml"
  grep -F -q "password: ${ZT_DPU_BMC_ROOT_PASSWORD}" "$zt_bmc_secret" || die "Zero Trust BMC shared password was not rendered"
fi

zt_flavor="${GENERATED_DIR}/dpu-services/zero-trust/dpuflavor.yaml"
grep -F -q "NUM_OF_VFS=${NUM_VFS}" "$zt_flavor" || die "Zero Trust DPUFlavor NUM_VFS was not rendered"
grep -F -q 'dpuMode: zero-trust' "$zt_flavor" || die "Zero Trust DPUFlavor is missing dpuMode: zero-trust"

zt_template="${GENERATED_DIR}/dpu-services/zero-trust/dpuservicetemplate.yaml"
grep -F -q "version: \"${HBN_HELM_CHART_VERSION}\"" "$zt_template" || die "Zero Trust HBN chart version was not rendered"
grep -F -q "tag: \"${HBN_IMAGE_TAG}\"" "$zt_template" || die "Zero Trust HBN image tag was not rendered"

zt_hbn_out="${GENERATED_DIR}/dpu-services/zero-trust/hbn-configuration.yaml"
grep -q '{{ ipaddresses.ip_lo.ip }}' "$zt_hbn_out" || die "Zero Trust HBN Jinja template was stripped"
grep -q '{{ config.bgp_autonomous_system }}' "$zt_hbn_out" || die "Zero Trust HBN Jinja template was stripped"
if grep -F -q '${DPU_VALUES}' "$zt_hbn_out"; then
  die "Zero Trust HBN perDPUValuesYAML placeholder was not substituted (DPU_VALUES is set by dpu-services.sh, not render_all)"
fi

zt_ipam="${GENERATED_DIR}/dpu-services/zero-trust/dpuservice-ipam.yaml"
grep -F -q "network: \"${ZT_HBN_POOL1_CIDR}\"" "$zt_ipam" || die "Zero Trust pool1 CIDR was not rendered"
grep -F -q "network: \"${ZT_HBN_POOL2_CIDR}\"" "$zt_ipam" || die "Zero Trust pool2 CIDR was not rendered"
grep -F -q "network: \"${ZT_HBN_LOOPBACK_CIDR}\"" "$zt_ipam" || die "Zero Trust loopback CIDR was not rendered"

zt_iface="${GENERATED_DIR}/dpu-services/zero-trust/dpuserviceinterface.yaml"
grep -F -q 'uplink: "p0"' "$zt_iface" || die "Zero Trust DPUServiceInterface is missing p0"
grep -F -q 'interface: "pf0hpf"' "$zt_iface" || die "Zero Trust DPUServiceInterface is missing pf0hpf"

if [[ -n "${DPU1_SERIAL:-}" ]]; then
  # render_all() does not call use_dpu(), so this is a smoke test that the
  # per-DPU templates render at all; dpf.sh renders/applies them per DPU.
  [[ -f "${GENERATED_DIR}/dpf/zero-trust/dpudevice.yaml" ]] || die "Zero Trust DPUDevice template was not rendered"
  [[ -f "${GENERATED_DIR}/dpf/zero-trust/dpunode.yaml" ]] || die "Zero Trust DPUNode template was not rendered"
fi

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
