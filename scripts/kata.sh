#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

OSC_NAMESPACE="openshift-sandboxed-containers-operator"
SRIOV_DP_CONFIG_CR_NAME="bf3-vfs"

osc_csv_succeeded() {
  local phase
  phase="$(oc -n "$OSC_NAMESPACE" get csv \
    -l operators.coreos.com/sandboxed-containers-operator.openshift-sandboxed-containers-operator \
    -o jsonpath='{.items[0].status.phase}' 2>/dev/null || true)"
  [[ -n "$phase" ]] || phase="$(oc -n "$OSC_NAMESPACE" get csv -o jsonpath='{.items[0].status.phase}' 2>/dev/null || true)"
  [[ "$phase" == "Succeeded" ]]
}

wait_for_osc_csv() {
  log "Waiting up to ${WAIT_HOSTED}s for the OSC operator CSV to reach Succeeded"
  local start=$SECONDS
  while ! osc_csv_succeeded; do
    if ((SECONDS - start >= WAIT_HOSTED)); then
      oc -n "$OSC_NAMESPACE" get csv,subscription,installplan 2>/dev/null || true
      die "OSC operator CSV did not reach Succeeded after ${WAIT_HOSTED}s"
    fi
    sleep 10
  done
  log "OSC operator CSV is Succeeded"
}

wait_for_osc_webhook() {
  log "Waiting up to ${WAIT_MEDIUM}s for the OSC controller-manager webhook endpoint"
  local start=$SECONDS
  while ! oc get endpoints -n "$OSC_NAMESPACE" controller-manager-service \
    -o jsonpath='{.subsets[*].addresses[*].ip}' 2>/dev/null | grep -q .; do
    if ((SECONDS - start >= WAIT_MEDIUM)); then
      oc -n "$OSC_NAMESPACE" get deploy,pods,svc,endpoints -o wide || true
      die "OSC controller-manager webhook endpoint was not ready after ${WAIT_MEDIUM}s"
    fi
    sleep 10
  done
  log "OSC controller-manager webhook endpoint is ready"
}

ensure_osc() {
  if osc_csv_succeeded; then
    log "OSC operator already installed (CSV Succeeded), skipping create"
    return 0
  fi
  log "Installing OpenShift Sandboxed Containers operator"
  apply_manifest "$(manifest kata/01-osc-operator.yaml)"
  wait_for_osc_csv
}

# Selector matches no nodes so OSC does not label DPU hosts kata-oc.
ensure_kataconfig() {
  wait_for_osc_webhook
  log "Applying KataConfig example-kataconfig (selector matches no nodes; DPU hosts stay on ${KATA_WORKER_ROLE})"
  apply_manifest "$(manifest kata/02-kataconfig.yaml)"
}

warn_if_dpu_nodes_have_kata_oc_role() {
  local labeled
  labeled="$(oc get nodes -l node-role.kubernetes.io/kata-oc -o jsonpath='{.items[*].metadata.name}' 2>/dev/null || true)"
  if [[ -n "$labeled" ]]; then
    log "WARNING: nodes have node-role.kubernetes.io/kata-oc (conflicts with ${KATA_WORKER_ROLE}): ${labeled}"
    log "WARNING: remove it: oc label node <name> node-role.kubernetes.io/kata-oc-"
  fi
}

cluster_has_kata_sriov_pool() {
  local pools
  pools="$(oc get nodesriovdevicepluginconfig "$SRIOV_DP_CONFIG_CR_NAME" -n dpf-operator-system \
    -o jsonpath='{range .spec.devicePluginResources[*]}{.name}{"\n"}{end}' 2>/dev/null || true)"
  grep -Fxq "${KATA_SRIOV_POOL_NAME}" <<<"$pools"
}

ensure_kata_sriov_pool() {
  if cluster_has_kata_sriov_pool; then
    log "NodeSRIOVDevicePluginConfig already has the kata pool ${KATA_SRIOV_POOL_NAME}"
    return 0
  fi
  log "Kata VF pool missing from NodeSRIOVDevicePluginConfig; regenerating and applying"
  compute_sriov_vf_ranges
  apply_manifest "$(manifest dpu-services/nodesriovdevicepluginconfig.yaml)"
  oc get nodesriovdevicepluginconfig -n dpf-operator-system
}

ensure_machineconfigs() {
  if oc get machineconfig 99-kata-dpu >/dev/null 2>&1; then
    log "Removing combined MachineConfig 99-kata-dpu (replaced by split MachineConfigs)"
    oc delete machineconfig 99-kata-dpu
  fi

  if [[ "$KATA_SKIP_RHCOS_LAYER" == "true" ]]; then
    log "KATA_SKIP_RHCOS_LAYER=true: omitting the RHCOS layer MachineConfig (z-stream kata RPM path)"
    if oc get machineconfig 99-kata-dpu-layered >/dev/null 2>&1; then
      log "Deleting leftover MachineConfig 99-kata-dpu-layered"
      oc delete machineconfig 99-kata-dpu-layered
    fi
  else
    apply_manifest "$(manifest kata/03-rhcos-layer.yaml)"
  fi

  apply_manifest "$(manifest kata/03-iommu.yaml)"
  apply_manifest "$(manifest kata/04-kata-coldplug.yaml)"
}

wait_for_api() {
  log "Waiting for the API to return"
  until oc get nodes >/dev/null 2>&1; do
    sleep 15
  done
}

wait_for_mcp() {
  local pool="$1"
  log "Waiting up to ${WAIT_HOSTED}s for MachineConfigPool ${pool} to finish rolling out (nodes may reboot)"
  local start=$SECONDS ready total updated degraded
  while true; do
    if ! oc get nodes >/dev/null 2>&1; then
      log "API unavailable (node rebooting)"
      wait_for_api
      sleep 15
      continue
    fi

    ready="$(oc get mcp "$pool" -o jsonpath='{.status.readyMachineCount}' 2>/dev/null || true)"
    total="$(oc get mcp "$pool" -o jsonpath='{.status.machineCount}' 2>/dev/null || true)"
    updated="$(oc get mcp "$pool" -o jsonpath='{.status.updatedMachineCount}' 2>/dev/null || true)"
    degraded="$(oc get mcp "$pool" -o jsonpath='{.status.degradedMachineCount}' 2>/dev/null || echo 0)"
    log "MCP ${pool}: ready=${ready:-?}/${total:-?} updated=${updated:-?} degraded=${degraded:-?}"

    if [[ "${degraded:-0}" != "0" ]]; then
      oc get mcp "$pool" -o jsonpath='{.status.conditions[?(@.type=="Degraded")].message}' || true
      echo
      die "MachineConfigPool ${pool} is degraded"
    fi

    if [[ -n "$ready" && -n "$total" && "$total" != "0" && "$ready" == "$total" && "$updated" == "$total" ]]; then
      log "MachineConfigPool ${pool} is fully updated"
      return 0
    fi

    if ((SECONDS - start >= WAIT_HOSTED)); then
      oc get mcp "$pool" || true
      die "Timed out waiting for MachineConfigPool ${pool}"
    fi
    sleep 20
  done
}

wait_for_runtimeclass() {
  local name="$1"
  local start=$SECONDS
  while ! oc get runtimeclass "$name" >/dev/null 2>&1; do
    if ((SECONDS - start >= WAIT_SHORT)); then
      die "RuntimeClass ${name} did not appear within ${WAIT_SHORT}s"
    fi
    sleep 10
  done
  log "RuntimeClass ${name} exists"
}

ensure_runtimeclass() {
  log "Applying RuntimeClass ${KATA_RUNTIME_CLASS} (nodeSelector ${KATA_WORKER_ROLE})"
  apply_manifest "$(manifest kata/05-runtimeclass.yaml)"
  wait_for_runtimeclass "$KATA_RUNTIME_CLASS"
}

check_kvm_on_workers() {
  local role="$1"
  local nodes node out
  nodes="$(oc get nodes -l "node-role.kubernetes.io/${role}=" -o jsonpath='{.items[*].metadata.name}' 2>/dev/null || true)"
  if [[ -z "$nodes" ]]; then
    log "WARNING: no nodes with role ${role} found; skipping /dev/kvm check"
    return 0
  fi
  for node in $nodes; do
    log "Checking /dev/kvm on ${node}"
    if ! out="$(oc debug "node/${node}" --to-namespace=default --quiet -- chroot /host sh -c '
      if [ -e /dev/kvm ]; then
        echo KATA_KVM_DEVICE_PRESENT
      else
        echo KATA_KVM_DEVICE_MISSING
      fi
    ' 2>&1)"; then
      die "Unable to inspect /dev/kvm on ${node}: ${out}"
    fi
    if grep -q '^KATA_KVM_DEVICE_MISSING$' <<<"$out"; then
      die "/dev/kvm is absent on ${node}. Confirm VMX/SVM is enabled and the host was cold-booted after changing firmware settings."
    elif ! grep -q '^KATA_KVM_DEVICE_PRESENT$' <<<"$out"; then
      die "Unable to determine /dev/kvm status on ${node}: ${out}"
    fi
  done
}

render_test_deployment() {
  export KATA_WORKER_ROLE
  KATA_WORKER_ROLE="$(kata_worker_role)"
}

deploy_kata_test() {
  require_cmds oc envsubst
  require_cluster
  require_kata_vars
  render_test_deployment
  oc delete pod kata-dpu-test --ignore-not-found --wait=false >/dev/null 2>&1 || true
  apply_manifest "$(manifest kata/06-test-deployment.yaml)"
  if [[ "$KATA_TEST_REPLICAS" == "0" ]]; then
    log "KATA_TEST_REPLICAS=0: scaled kata-dpu-test to zero"
    return 0
  fi
  local timeout=$((KATA_TEST_REPLICAS * 180))
  log "Waiting up to ${timeout}s for deployment/kata-dpu-test (${KATA_TEST_REPLICAS} replicas)"
  oc wait --for=condition=Available deployment/kata-dpu-test --timeout="${timeout}s"
  oc get pods -l app=kata-dpu-test -o wide
  log "Verify one replica: oc exec deploy/kata-dpu-test -- ping -c 3 8.8.8.8"
}

cleanup_stale_vfs() {
  require_cmds oc
  require_cluster
  export KATA_WORKER_ROLE
  KATA_WORKER_ROLE="$(kata_worker_role)"

  local kata_pods
  kata_pods="$(oc get pods -A -o custom-columns=NS:.metadata.namespace,NAME:.metadata.name,RC:.spec.runtimeClassName,PHASE:.status.phase --no-headers 2>/dev/null \
    | awk -v rc="${KATA_RUNTIME_CLASS:-kata-coldplug}" '$3==rc && $4!="Succeeded" && $4!="Failed" {print $1"/"$2" "$4}')"
  if [[ -n "$kata_pods" && "${FORCE:-false}" != "true" ]]; then
    log "ERROR: Kata pods are still present; rebinding would unplug VFs in use:"
    printf '%s\n' "$kata_pods"
    die "Delete or scale them down first, then re-run. Override with FORCE=true."
  fi

  local nodes node
  nodes="$(oc get nodes -l "node-role.kubernetes.io/${KATA_WORKER_ROLE}=" -o jsonpath='{.items[*].metadata.name}' 2>/dev/null || true)"
  [[ -n "$nodes" ]] || die "No nodes with role ${KATA_WORKER_ROLE} found"

  for node in $nodes; do
    log "Rebinding stale VFIO VFs on ${node}"
    oc debug "node/${node}" --to-namespace=default --quiet -- chroot /host bash -c '
for pf in $(ls /sys/class/net | grep np); do
  for vf in /sys/class/net/$pf/device/virtfn*; do
    [ -e "$vf" ] || continue
    pci=$(basename $(readlink $vf))
    driver=$(basename $(readlink /sys/bus/pci/devices/$pci/driver 2>/dev/null) 2>/dev/null || echo UNBOUND)
    override=$(cat /sys/bus/pci/devices/$pci/driver_override 2>/dev/null)
    [ "$override" = "vfio-pci" ] || override=""
    if [ "$driver" != "vfio-pci" ] && [ "$driver" != "UNBOUND" ] && [ -z "$override" ]; then
      continue
    fi
    echo "" > /sys/bus/pci/devices/$pci/driver_override
    [ -e /sys/bus/pci/devices/$pci/driver/unbind ] && echo $pci > /sys/bus/pci/devices/$pci/driver/unbind
    echo $pci > /sys/bus/pci/drivers/mlx5_core/bind 2>/dev/null || true
    new_driver=$(basename $(readlink /sys/bus/pci/devices/$pci/driver 2>/dev/null) 2>/dev/null || echo UNBOUND)
    echo "Rebound $pci driver $driver -> $new_driver"
  done
done
'
  done
  log "Stale VF cleanup finished"
}

enable_kata() {
  log "Phase: kata"
  require_cmds oc envsubst
  require_cluster

  if is_zero_trust; then
    die "DPF_DEPLOYMENT_MODE=zero-trust does not deploy the OVN-Kubernetes DPU service, so Kata support is a host-trusted-only operation."
  fi

  if [[ "${KATA_ENABLED:-false}" != "true" ]]; then
    die "KATA_ENABLED is not true. Set KATA_ENABLED=true, run 'make dpu-services' and 'make injector' again, then re-run 'make kata'."
  fi
  require_kata_vars

  export KATA_WORKER_ROLE
  KATA_WORKER_ROLE="$(kata_worker_role)"
  log "Enabling Kata DPU cold-plug on MachineConfigPool ${KATA_WORKER_ROLE}"

  oc get mcp "$KATA_WORKER_ROLE" >/dev/null 2>&1 \
    || die "MachineConfigPool ${KATA_WORKER_ROLE} not found. Run 'make platform' and 'make dpu-services' first."

  oc get net-attach-def -n openshift-ovn-kubernetes "$KATA_NAD_NAME" >/dev/null 2>&1 \
    || die "NetworkAttachmentDefinition '${KATA_NAD_NAME}' not found in openshift-ovn-kubernetes. Run 'make injector' with KATA_ENABLED=true first."

  check_kvm_on_workers "$KATA_WORKER_ROLE"
  ensure_kata_sriov_pool

  ensure_osc
  ensure_kataconfig
  warn_if_dpu_nodes_have_kata_oc_role
  ensure_machineconfigs
  wait_for_mcp "$KATA_WORKER_ROLE"

  ensure_runtimeclass

  log "Kata DPU cold-plug enabled (RuntimeClass ${KATA_RUNTIME_CLASS} on role ${KATA_WORKER_ROLE})"
  log "Deploy test pods: make deploy-kata-test"
}

case "${1:-enable}" in
  enable)
    enable_kata
    ;;
  deploy-test)
    deploy_kata_test
    ;;
  cleanup-vfs)
    cleanup_stale_vfs
    ;;
  *)
    die "Unknown command: $1 (available: enable, deploy-test, cleanup-vfs)"
    ;;
esac
