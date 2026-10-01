#!/usr/bin/env bash
# Shared helpers for the DPF installer. Source this file; do not execute it.

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  echo "ERROR: scripts/lib.sh is a library" >&2
  exit 1
fi

if [[ -n "${DPF_LIB_LOADED:-}" ]]; then
  return 0
fi
DPF_LIB_LOADED=1

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MANIFESTS_DIR="${ROOT}/manifests"
GENERATED_DIR="${ROOT}/generated/manifests"

ENV_VARS=(
  HOST_CLUSTER_API
  BASE_DOMAIN
  NODES_MTU
  TARGETCLUSTER_API_SERVER_PORT
  FLANNEL_POD_CIDR
  NUM_VFS
  BFB_URL
  BFB_ATF
  BFB_BSP
  BFB_DOCA
  BFB_UEFI
  OVN_MTU
  OVN_POD_NETWORK
  OVN_SERVICE_NETWORK
  VTEP_CIDR
  DPU_HOST_CIDR
  HOSTED_CLUSTER_NAME
  CLUSTERS_NAMESPACE
  ETCD_STORAGE_CLASS
  OCP_RELEASE_IMAGE
  PULL_SECRET_NAME
  SSH_KEY_SECRET_NAME
  HOSTED_CLUSTER_VIP
  WORKER_NAME
  BMC_USER
  BMC_PASSWORD
  BOOT_MAC
  ROOT_DEVICE
  BMC_IP
  GITOPS_OPERATOR_CHANNEL
  GITOPS_OPERATOR_CSV
)

log() {
  printf '==> %s\n' "$*"
}

die() {
  printf 'ERROR: %s\n' "$*" >&2
  exit 1
}

strip_quotes() {
  local value="$1"
  if [[ "$value" == \"*\" ]]; then
    value="${value:1:${#value}-2}"
  elif [[ "$value" == \'*\' ]]; then
    value="${value:1:${#value}-2}"
  fi
  printf '%s' "$value"
}

trim() {
  local s="$1"
  s="${s#"${s%%[![:space:]]*}"}"
  s="${s%"${s##*[![:space:]]}"}"
  printf '%s' "$s"
}

# Drop ambient values so a shell KUBECONFIG or CLUSTER_NAME cannot retarget the install.
MANAGED_VARS=(
  "${ENV_VARS[@]}"
  KUBECONFIG OPENSHIFT_PULL_SECRET SSH_KEY
  CLUSTER_NAME OPENSHIFT_VERSION WORKER_COUNT
  DPU_WORKER_CONFIG_CHART DPU_WORKER_CONFIG_VERSION
  MAINTENANCE_OPERATOR_CHART MAINTENANCE_OPERATOR_VERSION
  DPF_HELM_REPO DPF_VERSION
  OVN_TEMPLATE_CHART_URL OVN_CHART_VERSION
  DPF_HCP_PROVISIONER_CHART DPF_HCP_PROVISIONER_VERSION
  GRAFANA_OPERATOR_CHART GRAFANA_OPERATOR_VERSION
  HELM_TIMEOUT WAIT_SHORT WAIT_MEDIUM WAIT_CONDITIONS WAIT_HOSTED
  WORKER_JOIN_TIMEOUT DPU_READY_TIMEOUT APPLY_RETRIES
)

load_env() {
  local env_file="${ROOT}/.env"
  local line key value v
  [[ -f "$env_file" ]] || die "Missing ${env_file}. Copy .env.example to .env and edit it."

  for v in "${MANAGED_VARS[@]}"; do
    unset "$v"
  done
  for v in $(compgen -e); do
    if [[ "$v" =~ ^WORKER_[0-9]+_ ]]; then
      unset "$v"
    fi
  done

  while IFS= read -r line || [[ -n "$line" ]]; do
    line="$(trim "${line%$'\r'}")"
    [[ "$line" =~ ^# ]] && continue
    [[ -z "$line" ]] && continue
    [[ "$line" =~ ^[A-Za-z_][A-Za-z0-9_]*= ]] || die "Invalid .env line: ${line}"
    key="${line%%=*}"
    value="$(trim "$(strip_quotes "$(trim "${line#*=}")")")"
    export "$key=$value"
  done <"$env_file"
}

apply_derived() {
  if [[ -n "${CLUSTER_NAME:-}" && -n "${BASE_DOMAIN:-}" ]]; then
    : "${HOST_CLUSTER_API:=api.${CLUSTER_NAME}.${BASE_DOMAIN}}"
  fi
  if [[ -n "${OPENSHIFT_VERSION:-}" ]]; then
    : "${OCP_RELEASE_IMAGE:=quay.io/openshift-release-dev/ocp-release:${OPENSHIFT_VERSION}-multi}"
  fi

  : "${TARGETCLUSTER_API_SERVER_PORT:=6443}"
  : "${CLUSTERS_NAMESPACE:=clusters}"
  : "${PULL_SECRET_NAME:=pull-secret}"
  : "${SSH_KEY_SECRET_NAME:=ssh-key}"
  : "${WORKER_COUNT:=1}"
  : "${DPU_WORKER_CONFIG_CHART:=oci://registry.redhat.io/dpu-kit-for-nvidia/dpu-worker-config-chart}"
  : "${DPU_WORKER_CONFIG_VERSION:=4.22.0}"
  : "${MAINTENANCE_OPERATOR_CHART:=oci://ghcr.io/mellanox/maintenance-operator-chart}"
  : "${MAINTENANCE_OPERATOR_VERSION:=0.3.0}"
  : "${DPF_HELM_REPO:=https://helm.ngc.nvidia.com/nvidia/doca}"
  : "${DPF_VERSION:=v26.4.1}"
  : "${OVN_TEMPLATE_CHART_URL:=oci://ghcr.io/mellanox/charts}"
  : "${OVN_CHART_VERSION:=v26.4.1-ocp-release-v4.22}"
  : "${OVN_POD_NETWORK:=10.128.0.0/14/23}"
  : "${OVN_SERVICE_NETWORK:=172.30.0.0/16}"
  : "${DPF_HCP_PROVISIONER_CHART:=oci://registry.redhat.io/dpu-kit-for-nvidia/dpf-hcp-provisioner-chart}"
  : "${DPF_HCP_PROVISIONER_VERSION:=4.22.0}"
  : "${GRAFANA_OPERATOR_CHART:=oci://ghcr.io/grafana/helm-charts/grafana-operator}"
  : "${GRAFANA_OPERATOR_VERSION:=5.24.0}"
  : "${GITOPS_OPERATOR_CHANNEL:=gitops-1.21}"
  : "${GITOPS_OPERATOR_CSV:=openshift-gitops-operator.v1.21.3}"
  : "${BFB_ATF:=4.15.0-4-g419fbf393}"
  : "${BFB_BSP:=4.15.0.13998}"
  : "${BFB_DOCA:=3.4.1}"
  : "${BFB_UEFI:=4.15.0-19-g37c6f5adb2}"
  : "${HELM_TIMEOUT:=15m}"
  : "${WAIT_SHORT:=180}"
  : "${WAIT_MEDIUM:=600}"
  : "${WAIT_CONDITIONS:=1200}"
  : "${WAIT_HOSTED:=1800}"
  : "${WORKER_JOIN_TIMEOUT:=3600}"
  : "${DPU_READY_TIMEOUT:=3600}"
  : "${APPLY_RETRIES:=12}"

  export HOST_CLUSTER_API OCP_RELEASE_IMAGE TARGETCLUSTER_API_SERVER_PORT \
    CLUSTERS_NAMESPACE PULL_SECRET_NAME SSH_KEY_SECRET_NAME WORKER_COUNT \
    DPU_WORKER_CONFIG_CHART DPU_WORKER_CONFIG_VERSION \
    MAINTENANCE_OPERATOR_CHART MAINTENANCE_OPERATOR_VERSION \
    DPF_HELM_REPO DPF_VERSION \
    OVN_TEMPLATE_CHART_URL OVN_CHART_VERSION OVN_POD_NETWORK OVN_SERVICE_NETWORK \
    DPF_HCP_PROVISIONER_CHART DPF_HCP_PROVISIONER_VERSION \
    GRAFANA_OPERATOR_CHART GRAFANA_OPERATOR_VERSION \
    GITOPS_OPERATOR_CHANNEL GITOPS_OPERATOR_CSV \
    BFB_ATF BFB_BSP BFB_DOCA BFB_UEFI \
    HELM_TIMEOUT WAIT_SHORT WAIT_MEDIUM WAIT_CONDITIONS WAIT_HOSTED \
    WORKER_JOIN_TIMEOUT DPU_READY_TIMEOUT APPLY_RETRIES

  resolve_path_var KUBECONFIG
  resolve_path_var OPENSHIFT_PULL_SECRET
  resolve_path_var SSH_KEY
}

resolve_path_var() {
  local name="$1"
  local value="${!name:-}"
  [[ -n "$value" ]] || return 0
  if [[ "$value" != /* ]]; then
    value="${ROOT}/${value}"
  fi
  export "$name=$value"
}

build_envsubst_format() {
  local v fmt=""
  for v in "${ENV_VARS[@]}"; do
    fmt+=" \${${v}}"
  done
  ENVSUBST_FORMAT="${fmt# }"
}

require_cmds() {
  local c
  for c in "$@"; do
    command -v "$c" >/dev/null 2>&1 || die "Required command not found: ${c}"
  done
}

require_vars() {
  local v missing=()
  for v in "$@"; do
    if [[ -z "${!v:-}" ]]; then
      missing+=("$v")
    fi
  done
  if ((${#missing[@]} > 0)); then
    die "Missing or empty in .env: ${missing[*]}"
  fi
}

require_file() {
  local path="$1"
  local label="$2"
  [[ -f "$path" ]] || die "${label} not found: ${path}"
}

require_cluster() {
  require_vars KUBECONFIG
  require_file "$KUBECONFIG" "KUBECONFIG"
  export KUBECONFIG
}

require_seconds() {
  local name="$1"
  [[ "${!name}" =~ ^[0-9]+$ ]] || die "${name} must be a number of seconds (got '${!name}')"
}

require_common() {
  require_vars \
    KUBECONFIG OPENSHIFT_PULL_SECRET SSH_KEY \
    CLUSTER_NAME BASE_DOMAIN HOST_CLUSTER_API \
    OPENSHIFT_VERSION OCP_RELEASE_IMAGE \
    VTEP_CIDR NUM_VFS NODES_MTU OVN_MTU \
    DPU_HOST_CIDR FLANNEL_POD_CIDR BFB_URL \
    HOSTED_CLUSTER_NAME CLUSTERS_NAMESPACE ETCD_STORAGE_CLASS HOSTED_CLUSTER_VIP \
    PULL_SECRET_NAME SSH_KEY_SECRET_NAME \
    DPU_WORKER_CONFIG_VERSION MAINTENANCE_OPERATOR_VERSION \
    DPF_HELM_REPO DPF_VERSION OVN_CHART_VERSION DPF_HCP_PROVISIONER_VERSION \
    GITOPS_OPERATOR_CHANNEL GITOPS_OPERATOR_CSV \
    TARGETCLUSTER_API_SERVER_PORT
  require_seconds WAIT_SHORT
  require_seconds WAIT_MEDIUM
  require_seconds WAIT_CONDITIONS
  require_seconds WAIT_HOSTED
  require_seconds WORKER_JOIN_TIMEOUT
  require_seconds DPU_READY_TIMEOUT
  require_cluster
  require_file "$OPENSHIFT_PULL_SECRET" "OPENSHIFT_PULL_SECRET"
  require_file "$SSH_KEY" "SSH_KEY"
  grep -q '"auths"' "$OPENSHIFT_PULL_SECRET" \
    || die "OPENSHIFT_PULL_SECRET does not look like a docker config JSON: ${OPENSHIFT_PULL_SECRET}"
  grep -Eq '^(ssh-|ecdsa-)' "$SSH_KEY" \
    || die "SSH_KEY does not look like a public key: ${SSH_KEY}"
  [[ "$WORKER_COUNT" =~ ^[0-9]+$ ]] || die "WORKER_COUNT must be a number"
  require_nodes_mtu
}

# There is a DPUFlavor for each of these MTUs: manifests/dpu-services/dpuflavor-<MTU>.yaml
require_nodes_mtu() {
  [[ "$NODES_MTU" == "1500" || "$NODES_MTU" == "9000" ]] \
    || die "NODES_MTU must be 1500 (standard MTU) or 9000 (jumbo frames) (got '${NODES_MTU}')"
}

require_workers() {
  local i field name
  if [[ "$WORKER_COUNT" == "0" ]]; then
    return 0
  fi
  require_vars WORKER_NAME BMC_IP BMC_USER BMC_PASSWORD BOOT_MAC ROOT_DEVICE
  for ((i = 2; i <= WORKER_COUNT; i++)); do
    for field in NAME BMC_IP BMC_USER BMC_PASSWORD BOOT_MAC ROOT_DEVICE; do
      name="WORKER_${i}_${field}"
      [[ -n "${!name:-}" ]] || die "Missing ${name} in .env (WORKER_COUNT=${WORKER_COUNT})"
    done
  done
}

require_install_vars() {
  require_common
  require_workers
}

is_template() {
  case "$(basename "$1")" in
    gitops-operator.yaml | nfd-instance.yaml | dpfoperatorconfig.yaml | dpuflavor-1500.yaml | dpuflavor-9000.yaml | bfb.yaml | ovn-k.yaml | dpuservice-nad.yaml | dpuservice-ipam.yaml | dpucluster.yaml | dpfhcpprovisioner.yaml | bmc-secret.yaml | baremetalhost.yaml)
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

render() {
  envsubst "$ENVSUBST_FORMAT" <"$1"
}

stage_manifest() {
  local src="$1"
  local rel="${src#"${MANIFESTS_DIR}/"}"
  local dest="${GENERATED_DIR}/${rel}"
  mkdir -p "$(dirname "$dest")"
  if is_template "$src"; then
    render "$src" >"$dest"
  else
    cp "$src" "$dest"
  fi
  if [[ "$(basename "$dest")" == "bmc-secret.yaml" ]]; then
    chmod 600 "$dest"
  fi
  printf '%s\n' "$dest"
}

render_all() {
  local f
  rm -rf "$GENERATED_DIR"
  mkdir -p "$GENERATED_DIR"
  chmod 700 "${ROOT}/generated"
  while IFS= read -r -d '' f; do
    stage_manifest "$f" >/dev/null
  done < <(find "$MANIFESTS_DIR" -type f -name '*.yaml' -print0)
}

apply_manifest() {
  local src="$1"
  local tries="${2:-$APPLY_RETRIES}"
  local dest i err
  dest="$(stage_manifest "$src")"
  log "Applying ${src#"${ROOT}/"}"
  for ((i = 1; i <= tries; i++)); do
    if err="$(oc apply -f "$dest" 2>&1)"; then
      printf '%s\n' "$err"
      return 0
    fi
    printf '%s\n' "$err" >&2
    if ((i == tries)); then
      die "oc apply failed for ${src#"${ROOT}/"}"
    fi
    if ! grep -Eq 'no matches for kind|webhook|connection refused|the server could not find the requested resource|failed calling webhook|etcdserver|i/o timeout|TLS handshake timeout|the server is currently unable' <<<"$err"; then
      die "oc apply failed for ${src#"${ROOT}/"}"
    fi
    log "Retrying ${src#"${ROOT}/"} (${i}/${tries})"
    sleep 10
  done
}

manifest() {
  printf '%s\n' "${MANIFESTS_DIR}/$1"
}

wait_pods_match() {
  local ns="$1"
  local pattern="$2"
  local timeout_s="$3"
  local start=$SECONDS lines notready
  log "Waiting up to ${timeout_s}s for pods matching '${pattern}' in ${ns}"
  while true; do
    lines="$(oc get pods -n "$ns" --no-headers 2>/dev/null | grep "$pattern" || true)"
    if [[ -n "$lines" ]]; then
      notready="$(awk '{
        split($2, a, "/")
        if (a[1] != a[2] || ($3 != "Running" && $3 != "Completed" && $3 != "Succeeded")) print
      }' <<<"$lines")"
      if [[ -z "$notready" ]]; then
        log "Pods matching '${pattern}' in ${ns} are ready"
        return 0
      fi
    fi
    if ((SECONDS - start >= timeout_s)); then
      oc get pods -n "$ns" || true
      die "Timed out waiting for pods matching '${pattern}' in ${ns}"
    fi
    sleep 10
  done
}

wait_rollout() {
  local ns="$1"
  local deploy="$2"
  local timeout_s="$3"
  local start=$SECONDS remaining
  log "Waiting up to ${timeout_s}s for deployment/${deploy} in ${ns}"
  while true; do
    if oc get "deployment/${deploy}" -n "$ns" >/dev/null 2>&1; then
      remaining=$((timeout_s - (SECONDS - start)))
      if ((remaining <= 0)); then
        die "Timed out waiting for deployment/${deploy} in ${ns}"
      fi
      oc rollout status "deployment/${deploy}" -n "$ns" --timeout="${remaining}s"
      return 0
    fi
    if ((SECONDS - start >= timeout_s)); then
      die "Timed out waiting for deployment/${deploy} to appear in ${ns}"
    fi
    sleep 5
  done
}

check_hypershift() {
  local enabled
  if ! oc get multiclusterengine mce >/dev/null 2>&1; then
    die "multiclusterengine/mce not found. This install expects Hypershift on the management cluster."
  fi
  enabled=$(oc get multiclusterengine mce -o jsonpath='{.spec.overrides.components[?(@.name=="hypershift")].enabled}')
  if [[ "$enabled" == "false" ]]; then
    die "Hypershift is disabled on multiclusterengine/mce. Enable spec.overrides.components[name=hypershift] before continuing."
  fi
  if [[ -z "$enabled" ]]; then
    log "multiclusterengine/mce has no hypershift override; assuming the platform default is enabled."
  else
    log "Hypershift component enabled: ${enabled}"
  fi
}

approve_pending_csrs() {
  local pending
  pending="$(oc get csr -o go-template='{{range .items}}{{if not .status}}{{.metadata.name}}{{"\n"}}{{end}}{{end}}')"
  if [[ -z "${pending//[[:space:]]/}" ]]; then
    return 0
  fi
  log "Approving pending certificate signing requests"
  printf '%s\n' "$pending" | xargs -r oc adm certificate approve
}

use_worker() {
  local i="$1"
  local name
  if ((i == 1)); then
    require_vars WORKER_NAME BMC_IP BMC_USER BMC_PASSWORD BOOT_MAC ROOT_DEVICE
    export WORKER_NAME BMC_IP BMC_USER BMC_PASSWORD BOOT_MAC ROOT_DEVICE
    return 0
  fi
  name="WORKER_${i}_NAME"
  export WORKER_NAME="${!name}"
  name="WORKER_${i}_BMC_IP"
  export BMC_IP="${!name}"
  name="WORKER_${i}_BMC_USER"
  export BMC_USER="${!name}"
  name="WORKER_${i}_BMC_PASSWORD"
  export BMC_PASSWORD="${!name}"
  name="WORKER_${i}_BOOT_MAC"
  export BOOT_MAC="${!name}"
  name="WORKER_${i}_ROOT_DEVICE"
  export ROOT_DEVICE="${!name}"
}

node_is_ready() {
  local node="$1"
  local ready
  oc get node "$node" >/dev/null 2>&1 || return 1
  ready="$(oc get node "$node" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}')"
  [[ "$ready" == "True" ]]
}

# Prints the worker node name when the Node object exists. Ready is not required.
# The name is the BMH name, the Redfish hostname, or that hostname's short form.
find_worker_node() {
  local bmh_name="$1"
  local hw="" short="" candidate="" node=""
  hw="$(oc get bmh "$bmh_name" -n openshift-machine-api -o jsonpath='{.status.hardware.hostname}' 2>/dev/null || true)"
  short="${hw%%.*}"
  for candidate in "$bmh_name" "$hw" "$short"; do
    [[ -n "$candidate" ]] || continue
    if oc get node "$candidate" >/dev/null 2>&1; then
      printf '%s\n' "$candidate"
      return 0
    fi
    node="$(oc get nodes -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' 2>/dev/null | awk -v n="$candidate" '$0 == n || index($0, n ".") == 1 { print; exit }' || true)"
    if [[ -n "$node" ]]; then
      printf '%s\n' "$node"
      return 0
    fi
  done
  return 1
}

# Sets WORKER_READY_NODE when the BareMetalHost's node is Ready.
worker_node_ready() {
  local bmh_name="$1"
  local node=""
  WORKER_READY_NODE=""
  node="$(find_worker_node "$bmh_name" || true)"
  [[ -n "$node" ]] || return 1
  if node_is_ready "$node"; then
    WORKER_READY_NODE="$node"
    return 0
  fi
  return 1
}

# First Ready node whose name is not in the space-separated baseline.
new_ready_node() {
  local baseline=" $1 "
  local name="" ready=""
  while IFS= read -r name; do
    [[ -n "$name" ]] || continue
    [[ "$baseline" == *" $name "* ]] && continue
    ready="$(oc get node "$name" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}')"
    if [[ "$ready" == "True" ]]; then
      printf '%s\n' "$name"
      return 0
    fi
  done < <(oc get nodes -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' 2>/dev/null || true)
  return 1
}

# TODO: HUMAN-REVIEW-003 - Flagged for human review priority 5, see .asadoc/human-review/05-HUMAN-REVIEW-003.md
apply_secret() {
  oc create secret "$@" --dry-run=client -o yaml | oc apply -f -
}

# Helm 4 server-side apply conflicts with another field manager, for example
# worker-dpu spec.paused. --force-conflicts keeps the chart's value on re-run.
# TODO: HUMAN-REVIEW-003 - Flagged for human review priority 5, see .asadoc/human-review/05-HUMAN-REVIEW-003.md
helm_upgrade() {
  local args=(upgrade --install --timeout "$HELM_TIMEOUT")
  if helm upgrade --help 2>/dev/null | grep -q -- '--force-conflicts'; then
    args+=(--force-conflicts)
  fi
  helm "${args[@]}" "$@"
}

load_env
apply_derived
build_envsubst_format
