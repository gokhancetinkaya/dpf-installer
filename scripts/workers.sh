#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

log "Phase: workers"
require_cmds oc envsubst
require_cluster

if is_zero_trust; then
  die "DPF_DEPLOYMENT_MODE=zero-trust provisions DPUs directly over Redfish during 'make dpf'; 'make workers' (BareMetalHost) is a host-trusted-only operation."
fi

if [[ "$WORKER_COUNT" == "0" ]]; then
  log "WORKER_COUNT=0, skipping worker provisioning"
  exit 0
fi
require_workers

apply_manifest "$(manifest workers/provisioning.yaml)"

log "Waiting for secret worker-dpu-user-data-managed"
secret_deadline=$((SECONDS + WAIT_MEDIUM))
while true; do
  if oc get secret worker-dpu-user-data-managed -n openshift-machine-api >/dev/null 2>&1; then
    break
  fi
  if ((SECONDS >= secret_deadline)); then
    die "Timed out waiting for secret worker-dpu-user-data-managed in openshift-machine-api. The HCP provisioner creates it."
  fi
  sleep 10
done

worker_index=1
while ((worker_index <= WORKER_COUNT)); do
  use_worker "$worker_index"
  log "Provisioning BareMetalHost ${WORKER_NAME}"
  if ! ping -c 1 -W 3 "$BMC_IP" >/dev/null 2>&1; then
    log "BMC ${BMC_IP} did not answer ping; continuing with Redfish virtual media"
  fi
  apply_manifest "$(manifest workers/bmc-secret.yaml)"
  apply_manifest "$(manifest workers/baremetalhost.yaml)"
  worker_index=$((worker_index + 1))
done

dpu_watch_pid=""
stop_dpu_watch() {
  if [[ -n "$dpu_watch_pid" ]]; then
    kill "$dpu_watch_pid" 2>/dev/null || true
    wait "$dpu_watch_pid" 2>/dev/null || true
    dpu_watch_pid=""
  fi
}
trap stop_dpu_watch EXIT

log "Watching DPUs in dpf-operator-system until the worker node is Ready"
oc get dpu -n dpf-operator-system -w &
dpu_watch_pid=$!

baseline="$(oc get nodes -o jsonpath='{range .items[*]}{.metadata.name}{" "}{end}' 2>/dev/null || true)"
claimed=""
script_dir="$(dirname "${BASH_SOURCE[0]}")"

# Apply the hosted-cluster privileged SCC binding before waiting for
# anything: the DOCA DPU-service DaemonSets are rejected by OpenShift SCC
# admission without it, so the DPU node can never become Ready. This must
# not depend on worker node detection, which fails on customDeploy BMHs
# with introspection disabled (the BMH hostname stays empty). Idempotent.
"${script_dir}/hosted-scc.sh"

worker_index=1
while ((worker_index <= WORKER_COUNT)); do
  use_worker "$worker_index"
  log "Waiting up to ${WORKER_JOIN_TIMEOUT}s for ${WORKER_NAME} to join"
  join_deadline=$((SECONDS + WORKER_JOIN_TIMEOUT))
  deadline_extended=0
  node_ready_logged=0
  dpu_wait_logged=0
  last_state=""
  last_hostname=""
  while true; do
    approve_pending_csrs
    # Fail fast when the discovered hardware is outside the supported
    # envelope: more than one DPU per node, or a non-dual-port DPU.
    validate_dpu_hardware
    state="$(oc get bmh "$WORKER_NAME" -n openshift-machine-api -o jsonpath='{.status.provisioning.state}' 2>/dev/null || true)"
    hostname="$(oc get bmh "$WORKER_NAME" -n openshift-machine-api -o jsonpath='{.status.hardware.hostname}' 2>/dev/null || true)"
    if [[ "$state" != "$last_state" || "$hostname" != "$last_hostname" ]]; then
      log "BareMetalHost ${WORKER_NAME}: state=${state:-unknown} hostname=${hostname:-unknown}"
      last_state="$state"
      last_hostname="$hostname"
    fi
    if [[ "$deadline_extended" == "0" ]] && [[ "$state" == "provisioned" ]]; then
      deadline_extended=1
      join_deadline=$((SECONDS + DPU_READY_TIMEOUT))
      log "BareMetalHost ${WORKER_NAME} is provisioned. Waiting up to ${DPU_READY_TIMEOUT}s for the worker node and its DPUs to become Ready."
    fi
    if worker_node_ready "$WORKER_NAME"; then
      if [[ "$node_ready_logged" == "0" ]]; then
        node_ready_logged=1
        log "Node ${WORKER_READY_NODE} is Ready"
        oc label node "${WORKER_READY_NODE}" k8s.ovn.org/dpu-host= --overwrite 2>/dev/null || true
      fi
      claimed+=" ${WORKER_READY_NODE}"
      # Do not finish on node readiness alone: the DPU can still be
      # provisioning, and exiting would leave it unwatched.
      if dpus_all_ready; then
        break
      elif [[ "$dpu_wait_logged" == "0" ]]; then
        dpu_wait_logged=1
        log "Node is Ready; waiting for its DPUs to become Ready as well"
      fi
    fi
    if new_node="$(new_ready_node "${baseline} ${claimed}")"; then
      if [[ "$node_ready_logged" == "0" ]]; then
        node_ready_logged=1
        log "Node ${new_node} is Ready"
        oc label node "${new_node}" k8s.ovn.org/dpu-host= --overwrite 2>/dev/null || true
      fi
      claimed+=" ${new_node}"
      if dpus_all_ready; then
        break
      elif [[ "$dpu_wait_logged" == "0" ]]; then
        dpu_wait_logged=1
        log "Node is Ready; waiting for its DPUs to become Ready as well"
      fi
    fi
    if ((SECONDS >= join_deadline)); then
      oc get bmh "$WORKER_NAME" -n openshift-machine-api || true
      oc get nodes || true
      oc get csr -o go-template='{{range .items}}{{if not .status}}{{.metadata.name}} {{.spec.signerName}} {{.spec.username}}{{"\n"}}{{end}}{{end}}' || true
      if [[ "$deadline_extended" == "1" ]]; then
        die "Timed out after ${DPU_READY_TIMEOUT}s waiting for ${WORKER_NAME} and its DPUs to become Ready. Re-run 'make workers'."
      fi
      die "Timed out waiting for ${WORKER_NAME} to be provisioned and join. Re-run 'make workers' to keep approving CSRs."
    fi
    sleep 20
  done
  worker_index=$((worker_index + 1))
done
log "Workers joined"
