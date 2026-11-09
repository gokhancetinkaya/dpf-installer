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
  ZT_DPU_DISCOVERY_NAME
  ZT_DPU_BMC_IP_RANGE_START
  ZT_DPU_BMC_IP_RANGE_END
  ZT_DPU_BMC_ROOT_PASSWORD
  ZT_BFB_REGISTRY_PORT
  ZT_HBN_POOL1_CIDR
  ZT_HBN_POOL2_CIDR
  ZT_HBN_LOOPBACK_CIDR
  ZT_CONTROL_PLANE_MTU
  HBN_HELM_REPO_URL
  HBN_HELM_CHART_VERSION
  HBN_IMAGE_REPO
  HBN_IMAGE_TAG
  SKIP_DPU_NODE_DISCOVERY
  DPU_SERIAL
  DPU_SERIAL_NUMBER
  DPU_BMC_IP
  DPU_VALUES
  KATA_RUNTIME_CLASS
  KATA_WORKER_ROLE
  KATA_RHCOS_LAYER_IMAGE
  KATA_TEST_REPLICAS
  SRIOV_PF0_REGULAR_START
  SRIOV_PF0_END
  SRIOV_PF1_END
  KATA_SRIOV_POOL
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
  CLUSTER_NAME HOSTED_OPENSHIFT_VERSION WORKER_COUNT
  DPU_WORKER_CONFIG_CHART DPU_WORKER_CONFIG_VERSION
  MAINTENANCE_OPERATOR_CHART MAINTENANCE_OPERATOR_VERSION
  DPF_HELM_REPO DPF_VERSION
  OVN_TEMPLATE_CHART_URL OVN_CHART_VERSION
  KATA_ENABLED KATA_NAD_NAME KATA_INJECTOR_RESOURCE_NAME
  KATA_NUM_VFS KATA_SRIOV_POOL_NAME KATA_SKIP_RHCOS_LAYER
  DPF_HCP_PROVISIONER_CHART DPF_HCP_PROVISIONER_VERSION \
  DPF_HCP_PROVISIONER_IMAGE_REPO DPF_HCP_PROVISIONER_IMAGE_TAG
  GRAFANA_OPERATOR_CHART GRAFANA_OPERATOR_VERSION
  HELM_TIMEOUT WAIT_SHORT WAIT_MEDIUM WAIT_CONDITIONS WAIT_HOSTED
  WORKER_JOIN_TIMEOUT DPU_READY_TIMEOUT APPLY_RETRIES
  DPF_DEPLOYMENT_MODE ZT_DPU_DISCOVERY_MODE
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
    if [[ "$v" =~ ^DPU[1-9][0-9]*_(SERIAL|BMC_IP)$ ]]; then
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
  if [[ -n "${HOSTED_OPENSHIFT_VERSION:-}" ]]; then
    : "${OCP_RELEASE_IMAGE:=quay.io/openshift-release-dev/ocp-release:${HOSTED_OPENSHIFT_VERSION}-multi}"
  fi
  : "${KATA_ENABLED:=false}"
  export HOST_CLUSTER_API OCP_RELEASE_IMAGE KATA_ENABLED

  case "$KATA_ENABLED" in
    true | false) ;;
    *) die "KATA_ENABLED must be 'true' or 'false' (got '${KATA_ENABLED}')" ;;
  esac

  require_vars \
    TARGETCLUSTER_API_SERVER_PORT CLUSTERS_NAMESPACE \
    PULL_SECRET_NAME SSH_KEY_SECRET_NAME WORKER_COUNT \
    DPU_WORKER_CONFIG_CHART DPU_WORKER_CONFIG_VERSION \
    MAINTENANCE_OPERATOR_CHART MAINTENANCE_OPERATOR_VERSION \
    DPF_HELM_REPO DPF_VERSION DPF_DEPLOYMENT_MODE \
    OVN_TEMPLATE_CHART_URL OVN_CHART_VERSION OVN_POD_NETWORK OVN_SERVICE_NETWORK \
    DPF_HCP_PROVISIONER_CHART DPF_HCP_PROVISIONER_VERSION \
    GRAFANA_OPERATOR_CHART GRAFANA_OPERATOR_VERSION \
    GITOPS_OPERATOR_CHANNEL GITOPS_OPERATOR_CSV \
    BFB_ATF BFB_BSP BFB_DOCA BFB_UEFI \
    HELM_TIMEOUT WAIT_SHORT WAIT_MEDIUM WAIT_CONDITIONS WAIT_HOSTED \
    WORKER_JOIN_TIMEOUT DPU_READY_TIMEOUT APPLY_RETRIES

  case "$DPF_DEPLOYMENT_MODE" in
    host-trusted | zero-trust) ;;
    *) die "DPF_DEPLOYMENT_MODE must be 'host-trusted' or 'zero-trust' (got '${DPF_DEPLOYMENT_MODE}')" ;;
  esac
  require_hosted_openshift_version_format

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
    HOSTED_OPENSHIFT_VERSION OCP_RELEASE_IMAGE \
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

# Tested OpenShift version-skew combinations. HyperShift supports running a
# hosted cluster on a different OCP version than the management cluster, but
# this installer's bundle (DPF version, BFB/DOCA, the OVN injector chart) has
# only been validated against the pairs below. Key is the management
# cluster's major.minor; value is a space-separated list of hosted
# major.minor versions tested against that management version. Add a row
# only after NVIDIA/QE validate the combination against this bundle. See the
# "Hosted and management OpenShift versions" section in README.md.
declare -A VERSION_SKEW_MATRIX=(
  ["4.22"]="4.22"
)

# Reduces a full x.y.z OpenShift version to its major.minor.
minor_version() {
  local v="$1" maj min patch
  IFS='.' read -r maj min patch <<<"$v"
  printf '%s.%s' "$maj" "$min"
}

require_hosted_openshift_version_format() {
  [[ "${HOSTED_OPENSHIFT_VERSION:-}" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] \
    || die "HOSTED_OPENSHIFT_VERSION must be a full OpenShift version x.y.z (got '${HOSTED_OPENSHIFT_VERSION:-}')"
}

# Confirms the configured hosted cluster version is a tested pairing with the
# management cluster's running version. Requires oc to already be
# authenticated against the management cluster (preflight runs this after
# `oc whoami`).
require_version_skew() {
  local mgmt_version mgmt_minor hosted_minor allowed
  require_hosted_openshift_version_format
  mgmt_version="$(oc get clusterversion version -o jsonpath='{.status.desired.version}' 2>/dev/null)" \
    || die "Could not read the management cluster's OpenShift version (oc get clusterversion version)"
  [[ -n "$mgmt_version" ]] || die "Management cluster OpenShift version is empty"
  mgmt_minor="$(minor_version "$mgmt_version")"
  hosted_minor="$(minor_version "$HOSTED_OPENSHIFT_VERSION")"
  allowed="${VERSION_SKEW_MATRIX[$mgmt_minor]:-}"
  [[ -n "$allowed" ]] \
    || die "Management cluster is running OpenShift ${mgmt_version} (${mgmt_minor}), which has no tested hosted-cluster versions in VERSION_SKEW_MATRIX (scripts/lib.sh). See README.md 'Hosted and management OpenShift versions'."
  [[ " ${allowed} " == *" ${hosted_minor} "* ]] \
    || die "HOSTED_OPENSHIFT_VERSION=${HOSTED_OPENSHIFT_VERSION} (${hosted_minor}) is not a tested pairing with management cluster OpenShift ${mgmt_version} (${mgmt_minor}). Tested hosted versions for management ${mgmt_minor}: ${allowed}. See README.md 'Hosted and management OpenShift versions'."
  log "Version skew ok: management OpenShift ${mgmt_version}, hosted OpenShift ${HOSTED_OPENSHIFT_VERSION}"
}

# NODES_MTU selects which DPUFlavor to apply.
require_nodes_mtu() {
  case "${NODES_MTU:-}" in
    9000|1500) ;;
    *) die "NODES_MTU must be 9000 or 1500 (got '${NODES_MTU:-}')" ;;
  esac
}

dpuflavor_manifest() {
  if is_zero_trust; then
    printf '%s\n' "dpu-services/zero-trust/dpuflavor.yaml"
    return 0
  fi
  require_nodes_mtu
  printf '%s\n' "dpu-services/dpuflavor-${NODES_MTU}.yaml"
}

dpfoperatorconfig_manifest() {
  if is_zero_trust; then
    printf '%s\n' "dpf/zero-trust/dpfoperatorconfig.yaml"
  else
    printf '%s\n' "dpf/dpfoperatorconfig.yaml"
  fi
}

require_workers() {
  local i field name
  # Zero Trust never provisions a BareMetalHost; WORKER_* variables are unused.
  if is_zero_trust; then
    return 0
  fi
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

####################################################################
# Kata helpers
#
# Kata support spans three phases: injector (runtime-class mapping on the
# OVN resource injector webhook), dpu-services (a dedicated SR-IOV VF pool),
# and kata (OSC operator, KataConfig, MachineConfigs, RuntimeClass). All are
# host-trusted only. See README.md "Kata support".
####################################################################

require_kata_vars() {
  require_vars KATA_RUNTIME_CLASS KATA_NAD_NAME KATA_INJECTOR_RESOURCE_NAME \
    KATA_NUM_VFS KATA_SRIOV_POOL_NAME KATA_RHCOS_LAYER_IMAGE KATA_TEST_REPLICAS
  : "${KATA_SKIP_RHCOS_LAYER:=false}"
  export KATA_SKIP_RHCOS_LAYER
  case "$KATA_SKIP_RHCOS_LAYER" in
    true | false) ;;
    *) die "KATA_SKIP_RHCOS_LAYER must be 'true' or 'false' (got '${KATA_SKIP_RHCOS_LAYER}')" ;;
  esac
  [[ "$KATA_NUM_VFS" =~ ^[1-9][0-9]*$ ]] || die "KATA_NUM_VFS must be a positive integer (got '${KATA_NUM_VFS}')"
  [[ "$KATA_TEST_REPLICAS" =~ ^[0-9]+$ ]] || die "KATA_TEST_REPLICAS must be a non-negative integer (got '${KATA_TEST_REPLICAS}')"
}

# DPU hosts are in MCP worker-dpu even when the management cluster is SNO.
kata_worker_role() {
  if oc get mcp worker-dpu >/dev/null 2>&1; then
    printf 'worker-dpu\n'
  else
    printf 'worker\n'
  fi
}

# Splits the regular PF0 VF range to carve out a dedicated Kata pool when
# KATA_ENABLED=true. Exports SRIOV_PF0_REGULAR_START, SRIOV_PF0_END,
# SRIOV_PF1_END, and KATA_SRIOV_POOL (a YAML devicePluginResources list item,
# or empty) for nodesriovdevicepluginconfig.yaml.
compute_sriov_vf_ranges() {
  local vf_range_end=$((NUM_VFS - 1))
  local pf0_regular_start=2
  KATA_SRIOV_POOL=""
  if [[ "${KATA_ENABLED:-false}" == "true" ]]; then
    require_vars KATA_NUM_VFS KATA_SRIOV_POOL_NAME
    [[ "$KATA_NUM_VFS" =~ ^[1-9][0-9]*$ ]] || die "KATA_NUM_VFS must be a positive integer (got '${KATA_NUM_VFS}')"
    ((pf0_regular_start + KATA_NUM_VFS < NUM_VFS)) || die "KATA_NUM_VFS (${KATA_NUM_VFS}) must be less than NUM_VFS - ${pf0_regular_start} ($((NUM_VFS - pf0_regular_start)))"
    local kata_vf_start=$pf0_regular_start
    local kata_vf_end=$((pf0_regular_start + KATA_NUM_VFS - 1))
    pf0_regular_start=$((kata_vf_end + 1))
    log "KATA_ENABLED=true: kata SR-IOV pool ${KATA_SRIOV_POOL_NAME} takes PF0 VFs ${kata_vf_start}-${kata_vf_end}; regular pool PF0 VFs ${pf0_regular_start}-${vf_range_end}"
    KATA_SRIOV_POOL="- name: ${KATA_SRIOV_POOL_NAME}
      type: vf
      ranges:
        - pfIndex: 0
          start: ${kata_vf_start}
          end: ${kata_vf_end}"
  fi
  export SRIOV_PF0_REGULAR_START="$pf0_regular_start"
  export SRIOV_PF0_END="$vf_range_end"
  export SRIOV_PF1_END="$vf_range_end"
  export KATA_SRIOV_POOL
}

is_template() {
  case "$(basename "$1")" in
    gitops-operator.yaml | nfd-instance.yaml | dpfoperatorconfig.yaml | dpuflavor-9000.yaml | dpuflavor-1500.yaml | bfb.yaml | ovn-k.yaml | dpuservice-nad.yaml | dpuservice-ipam.yaml | dpucluster.yaml | dpfhcpprovisioner.yaml | bmc-secret.yaml | baremetalhost.yaml | bmc-shared-password.yaml | bfb-registry-nodeport.yaml | dpudiscovery.yaml | dpudevice.yaml | dpunode.yaml | dpuflavor.yaml | dpuservicetemplate.yaml | hbn-configuration.yaml | nodesriovdevicepluginconfig.yaml | 03-iommu.yaml | 03-rhcos-layer.yaml | 04-kata-coldplug.yaml | 05-runtimeclass.yaml | 06-test-deployment.yaml)
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

apply_secret() {
  local ns="$1"
  shift
  oc create secret "$@" -n "$ns" --dry-run=client -o yaml | oc apply -f -
}

# Helm 4 server-side apply conflicts with another field manager, for example
# worker-dpu spec.paused. --force-conflicts keeps the chart's value on re-run.
helm_upgrade() {
  local args=(upgrade --install)
  if helm upgrade --help 2>/dev/null | grep -q -- '--force-conflicts'; then
    args+=(--force-conflicts)
  fi
  helm "${args[@]}" "$@"
}

####################################################################
# Zero Trust helpers
#
# Zero Trust mode never trusts the host OS: DPF provisions each DPU
# directly over its own BMC/Redfish instead of through a BareMetalHost.
# See the "Zero Trust mode" section in README.md.
####################################################################

is_zero_trust() {
  [[ "$DPF_DEPLOYMENT_MODE" == "zero-trust" ]]
}

# Prints DPU1_SERIAL, DPU2_SERIAL, DPU3_SERIAL, ... in numeric order.
# Additional numbered variables can be added to .env without changing scripts.
list_dpu_serial_variables() {
  compgen -A variable | grep -E '^DPU[1-9][0-9]*_SERIAL$' | sort -V || true
}

# Exports DPU_SERIAL, DPU_SERIAL_NUMBER, and DPU_BMC_IP for the DPU named by
# the given DPU<n>_SERIAL variable, for use by manifest() + apply_manifest().
use_dpu() {
  local serial_var="$1"
  local bmc_ip_var="${serial_var%_SERIAL}_BMC_IP"
  export DPU_SERIAL="${!serial_var}"
  export DPU_SERIAL_NUMBER="${DPU_SERIAL^^}"
  export DPU_BMC_IP="${!bmc_ip_var:-}"
}

ipv4_to_int() {
  local ip="$1" a b c d
  IFS=. read -r a b c d <<<"$ip" 2>/dev/null || return 1
  [[ "$a" =~ ^[0-9]{1,3}$ && "$b" =~ ^[0-9]{1,3}$ && "$c" =~ ^[0-9]{1,3}$ && "$d" =~ ^[0-9]{1,3}$ ]] || return 1
  ((a <= 255 && b <= 255 && c <= 255 && d <= 255)) || return 1
  printf '%d\n' "$(((a << 24) + (b << 16) + (c << 8) + d))"
}

valid_ipv4() {
  ipv4_to_int "$1" >/dev/null 2>&1
}

# Validates every DPF_DEPLOYMENT_MODE=zero-trust input in .env. Called from
# preflight (fail fast) and again from dpf.sh (phases are independently
# re-runnable, so each phase validates what it needs).
require_zero_trust() {
  require_vars ZT_DPU_BMC_ROOT_PASSWORD ZT_DPU_DISCOVERY_MODE ZT_CONTROL_PLANE_MTU ZT_BFB_REGISTRY_PORT \
    HBN_HELM_REPO_URL HBN_HELM_CHART_VERSION HBN_IMAGE_REPO HBN_IMAGE_TAG \
    ZT_HBN_POOL1_CIDR ZT_HBN_POOL2_CIDR ZT_HBN_LOOPBACK_CIDR
  : "${ZT_AUTO_POWER_CYCLE:=false}"
  : "${WAIT_EXTERNAL_REBOOT:=1800}"
  export ZT_AUTO_POWER_CYCLE WAIT_EXTERNAL_REBOOT
  case "$ZT_AUTO_POWER_CYCLE" in
    true | false) ;;
    *) die "ZT_AUTO_POWER_CYCLE must be 'true' or 'false' (got '${ZT_AUTO_POWER_CYCLE}')" ;;
  esac
  require_seconds WAIT_EXTERNAL_REBOOT
  [[ "$NODES_MTU" == "9000" ]] || die "DPF_DEPLOYMENT_MODE=zero-trust requires NODES_MTU=9000"
  # NVIDIA's Zero Trust documentation caps controlPlaneMTU at 1500, separate
  # from the 9000 high-speed/data-plane MTU set from NODES_MTU above.
  [[ "$ZT_CONTROL_PLANE_MTU" =~ ^[0-9]+$ ]] || die "ZT_CONTROL_PLANE_MTU must be a number (got '${ZT_CONTROL_PLANE_MTU}')"
  ((ZT_CONTROL_PLANE_MTU > 0 && ZT_CONTROL_PLANE_MTU <= 1500)) || die "ZT_CONTROL_PLANE_MTU must be between 1 and 1500 (got '${ZT_CONTROL_PLANE_MTU}')"
  # This is the NodePort on a Service this installer owns. It must stay in the
  # cluster NodePort range. The operator's own bfb-registry Service gets a new
  # port whenever it is recreated, so Redfish cannot use that port.
  [[ "$ZT_BFB_REGISTRY_PORT" =~ ^[0-9]+$ ]] || die "ZT_BFB_REGISTRY_PORT must be a number (got '${ZT_BFB_REGISTRY_PORT}')"
  ((ZT_BFB_REGISTRY_PORT >= 30000 && ZT_BFB_REGISTRY_PORT <= 32767)) || die "ZT_BFB_REGISTRY_PORT must be in the NodePort range 30000-32767 (got '${ZT_BFB_REGISTRY_PORT}')"

  case "$ZT_DPU_DISCOVERY_MODE" in
    scanning | static) ;;
    *) die "ZT_DPU_DISCOVERY_MODE must be 'scanning' or 'static' (got '${ZT_DPU_DISCOVERY_MODE}')" ;;
  esac

  [[ -n "${DPU1_SERIAL:-}" ]] || die "DPF_DEPLOYMENT_MODE=zero-trust requires at least DPU1_SERIAL"
  # The DPU is powered by the server chassis. Those BMCs are the WORKER_*
  # credentials; Zero Trust uses them only to turn the chassis on.
  [[ "${WORKER_COUNT}" =~ ^[0-9]+$ ]] || die "WORKER_COUNT must be a number (got '${WORKER_COUNT}')"
  ((WORKER_COUNT >= 1)) || die "DPF_DEPLOYMENT_MODE=zero-trust requires WORKER_COUNT >= 1. The server BMC powers the chassis the DPU is plugged into. No BareMetalHost is created."
  local host_index
  for ((host_index = 1; host_index <= WORKER_COUNT; host_index++)); do
    load_host_bmc "$host_index"
    [[ -n "$HOST_BMC_IP" ]] || die "Zero Trust requires the server BMC address for chassis ${host_index} (${HOST_BMC_NAME})"
    [[ -n "$HOST_BMC_USER" && -n "$HOST_BMC_PASSWORD" ]] || die "Zero Trust requires the server BMC user and password for chassis ${host_index} (${HOST_BMC_NAME})"
    valid_ipv4 "$HOST_BMC_IP" || die "Server BMC address for ${HOST_BMC_NAME} is not a valid IPv4 address: ${HOST_BMC_IP}"
  done

  local serial_var serial seen_serials=" "
  while IFS= read -r serial_var; do
    serial="${!serial_var}"
    [[ -n "$serial" ]] || continue
    [[ "$serial" =~ [[:upper:]] ]] && die "${serial_var} must be lowercase (got '${serial}')"
    [[ "$seen_serials" == *" ${serial} "* ]] && die "${serial_var} duplicates another DPU serial: ${serial}"
    seen_serials+="${serial} "
  done < <(list_dpu_serial_variables)

  if [[ "$ZT_DPU_DISCOVERY_MODE" == "static" ]]; then
    local bmc_ip_var bmc_ip seen_ips=" "
    while IFS= read -r serial_var; do
      serial="${!serial_var}"
      [[ -n "$serial" ]] || continue
      bmc_ip_var="${serial_var%_SERIAL}_BMC_IP"
      bmc_ip="${!bmc_ip_var:-}"
      [[ -n "$bmc_ip" ]] || die "Static Zero Trust inventory requires ${bmc_ip_var} for ${serial_var}"
      valid_ipv4 "$bmc_ip" || die "${bmc_ip_var} is not a valid IPv4 address: ${bmc_ip}"
      [[ "$seen_ips" == *" ${bmc_ip} "* ]] && die "${bmc_ip_var} duplicates another DPU BMC IP: ${bmc_ip}"
      seen_ips+="${bmc_ip} "
    done < <(list_dpu_serial_variables)
  else
    require_vars ZT_DPU_DISCOVERY_NAME ZT_DPU_BMC_IP_RANGE_START ZT_DPU_BMC_IP_RANGE_END
    local start_i end_i
    start_i=$(ipv4_to_int "$ZT_DPU_BMC_IP_RANGE_START") || die "ZT_DPU_BMC_IP_RANGE_START is not a valid IPv4 address: ${ZT_DPU_BMC_IP_RANGE_START}"
    end_i=$(ipv4_to_int "$ZT_DPU_BMC_IP_RANGE_END") || die "ZT_DPU_BMC_IP_RANGE_END is not a valid IPv4 address: ${ZT_DPU_BMC_IP_RANGE_END}"
    ((start_i <= end_i)) || die "ZT_DPU_BMC_IP_RANGE_START must not be greater than ZT_DPU_BMC_IP_RANGE_END"
  fi
}

# Loads HOST_BMC_NAME, HOST_BMC_IP, HOST_BMC_USER, and HOST_BMC_PASSWORD for
# chassis n. Chassis 1 uses the unnumbered BMC_* variables.
load_host_bmc() {
  local i="$1" name
  if ((i == 1)); then
    HOST_BMC_NAME="${WORKER_NAME:-worker-01}"
    HOST_BMC_IP="${BMC_IP:-}"
    HOST_BMC_USER="${BMC_USER:-}"
    HOST_BMC_PASSWORD="${BMC_PASSWORD:-}"
  else
    name="WORKER_${i}_NAME"
    HOST_BMC_NAME="${!name:-worker-${i}}"
    name="WORKER_${i}_BMC_IP"
    HOST_BMC_IP="${!name:-}"
    name="WORKER_${i}_BMC_USER"
    HOST_BMC_USER="${!name:-}"
    name="WORKER_${i}_BMC_PASSWORD"
    HOST_BMC_PASSWORD="${!name:-}"
  fi
  export HOST_BMC_NAME HOST_BMC_IP HOST_BMC_USER HOST_BMC_PASSWORD
}

# Performs one Redfish request against the server BMC in HOST_BMC_*.
# Prints the response body, then a line with the HTTP status code.
host_bmc_redfish() {
  local method="$1" url="$2" data="${3:-}"
  local cfg out
  command -v curl >/dev/null 2>&1 || die "curl is required to power the server chassis through its BMC"
  command -v python3 >/dev/null 2>&1 || die "python3 is required to read the server BMC Redfish response"
  cfg="$(mktemp)"
  chmod 600 "$cfg"
  export HOST_BMC_CURL_CONFIG="$cfg"
  python3 - <<'PY'
import os
path = os.environ["HOST_BMC_CURL_CONFIG"]
def esc(value):
    return value.replace("\\", "\\\\").replace('"', '\\"')
with open(path, "w") as fh:
    fh.write('user = "%s:%s"\n' % (esc(os.environ["HOST_BMC_USER"]), esc(os.environ["HOST_BMC_PASSWORD"])))
PY
  if [[ -n "$data" ]]; then
    out="$(curl -sk --config "$cfg" --connect-timeout 8 --max-time 20 \
      -X "$method" -H 'Content-Type: application/json' --data "$data" \
      -w $'\n%{http_code}' "$url" || true)"
  else
    out="$(curl -sk --config "$cfg" --connect-timeout 8 --max-time 20 \
      -X "$method" -w $'\n%{http_code}' "$url" || true)"
  fi
  rm -f "$cfg"
  printf '%s\n' "$out"
}

host_bmc_redfish_code() {
  printf '%s\n' "${1##*$'\n'}"
}

host_bmc_redfish_body() {
  local response="$1"
  printf '%s\n' "${response%$'\n'*}"
}

# Powers on every configured server chassis, then waits until each static
# DPU BMC answers. Already-on chassis are left alone. No BareMetalHost is created.
power_on_zero_trust_hosts() {
  local host_index start response code body system_path reset_path state serial_var serial bmc_ip
  log "Ensuring ${WORKER_COUNT} server chassis powered on for Zero Trust"
  for ((host_index = 1; host_index <= WORKER_COUNT; host_index++)); do
    load_host_bmc "$host_index"
    response="$(host_bmc_redfish GET "https://${HOST_BMC_IP}/redfish/v1/Systems")"
    code="$(host_bmc_redfish_code "$response")"
    body="$(host_bmc_redfish_body "$response")"
    [[ "$code" =~ ^2 ]] || die "Server BMC ${HOST_BMC_IP} (${HOST_BMC_NAME}) Redfish /Systems returned HTTP ${code}"
    system_path="$(printf '%s\n' "$body" | python3 -c 'import json,sys; d=json.load(sys.stdin); m=d.get("Members") or []; print(m[0].get("@odata.id","") if m else "")')"
    [[ -n "$system_path" ]] || die "Server BMC ${HOST_BMC_IP} (${HOST_BMC_NAME}) Redfish /Systems has no computer system"
    response="$(host_bmc_redfish GET "https://${HOST_BMC_IP}${system_path}")"
    code="$(host_bmc_redfish_code "$response")"
    body="$(host_bmc_redfish_body "$response")"
    [[ "$code" =~ ^2 ]] || die "Server BMC ${HOST_BMC_IP} (${HOST_BMC_NAME}) Redfish ${system_path} returned HTTP ${code}"
    state="$(printf '%s\n' "$body" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("PowerState",""))')"
    if [[ "$state" == "On" ]]; then
      log "Server chassis ${HOST_BMC_NAME} (${HOST_BMC_IP}) is already powered on"
      continue
    fi
    reset_path="$(printf '%s\n' "$body" | python3 -c 'import json,sys; d=json.load(sys.stdin); print(((d.get("Actions") or {}).get("#ComputerSystem.Reset") or {}).get("target",""))')"
    [[ -n "$reset_path" ]] || die "Server BMC ${HOST_BMC_IP} (${HOST_BMC_NAME}) has no Redfish power-on action"
    log "Powering on server chassis ${HOST_BMC_NAME} (${HOST_BMC_IP}), current state ${state:-unknown}"
    response="$(host_bmc_redfish POST "https://${HOST_BMC_IP}${reset_path}" '{"ResetType":"On"}')"
    code="$(host_bmc_redfish_code "$response")"
    [[ "$code" =~ ^2 ]] || die "Power-on request to server BMC ${HOST_BMC_IP} (${HOST_BMC_NAME}) returned HTTP ${code}"
    start=$SECONDS
    while [[ "$state" != "On" ]]; do
      if ((SECONDS - start >= WAIT_SHORT)); then
        die "Timed out after ${WAIT_SHORT}s waiting for server chassis ${HOST_BMC_NAME} (${HOST_BMC_IP}) to power on (last state ${state:-unknown})"
      fi
      sleep 5
      response="$(host_bmc_redfish GET "https://${HOST_BMC_IP}${system_path}")"
      body="$(host_bmc_redfish_body "$response")"
      state="$(printf '%s\n' "$body" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("PowerState",""))' 2>/dev/null || true)"
    done
    log "Server chassis ${HOST_BMC_NAME} (${HOST_BMC_IP}) is powered on"
  done

  wait_zero_trust_dpu_bmcs_reachable "powering on the server chassis"
}

# Waits for each statically configured DPU BMC to answer. Used after a
# chassis power-on or power-cycle. No-op in scanning mode, where BMC IPs
# aren't known individually, and silently skipped if curl is unavailable.
wait_zero_trust_dpu_bmcs_reachable() {
  local after="${1:-the chassis power event}"
  local serial_var serial bmc_ip start

  [[ "$ZT_DPU_DISCOVERY_MODE" == "static" ]] || return 0
  command -v curl >/dev/null 2>&1 || return 0
  log "Waiting up to ${WAIT_MEDIUM}s for each DPU BMC to answer after ${after}"
  while IFS= read -r serial_var; do
    serial="${!serial_var}"
    [[ -n "$serial" ]] || continue
    bmc_ip="${serial_var%_SERIAL}_BMC_IP"
    bmc_ip="${!bmc_ip}"
    start=$SECONDS
    while ! curl -k -u "root:${ZT_DPU_BMC_ROOT_PASSWORD}" -s -o /dev/null -f \
      --connect-timeout 5 --max-time 10 \
      "https://${bmc_ip}/redfish/v1/Systems/Bluefield"; do
      if ((SECONDS - start >= WAIT_MEDIUM)); then
        die "DPU ${serial} Redfish endpoint ${bmc_ip} did not answer within ${WAIT_MEDIUM}s of ${after}"
      fi
      sleep 10
    done
    log "DPU ${serial} Redfish endpoint ${bmc_ip} is reachable"
  done < <(list_dpu_serial_variables)
}

# Power-cycles every configured server chassis, regardless of current state.
# Used to satisfy a DPUNode's external-reboot requirement; see
# wait_zero_trust_external_reboots. Unlike power_on_zero_trust_hosts, this
# does not skip chassis that are already on: a cycle is the point.
power_cycle_zero_trust_hosts() {
  local host_index response code body system_path reset_path
  log "Power-cycling ${WORKER_COUNT} server chassis to apply pending DPU firmware config"
  for ((host_index = 1; host_index <= WORKER_COUNT; host_index++)); do
    load_host_bmc "$host_index"
    response="$(host_bmc_redfish GET "https://${HOST_BMC_IP}/redfish/v1/Systems")"
    code="$(host_bmc_redfish_code "$response")"
    body="$(host_bmc_redfish_body "$response")"
    [[ "$code" =~ ^2 ]] || die "Server BMC ${HOST_BMC_IP} (${HOST_BMC_NAME}) Redfish /Systems returned HTTP ${code}"
    system_path="$(printf '%s\n' "$body" | python3 -c 'import json,sys; d=json.load(sys.stdin); m=d.get("Members") or []; print(m[0].get("@odata.id","") if m else "")')"
    [[ -n "$system_path" ]] || die "Server BMC ${HOST_BMC_IP} (${HOST_BMC_NAME}) Redfish /Systems has no computer system"
    response="$(host_bmc_redfish GET "https://${HOST_BMC_IP}${system_path}")"
    code="$(host_bmc_redfish_code "$response")"
    body="$(host_bmc_redfish_body "$response")"
    [[ "$code" =~ ^2 ]] || die "Server BMC ${HOST_BMC_IP} (${HOST_BMC_NAME}) Redfish ${system_path} returned HTTP ${code}"
    reset_path="$(printf '%s\n' "$body" | python3 -c 'import json,sys; d=json.load(sys.stdin); print(((d.get("Actions") or {}).get("#ComputerSystem.Reset") or {}).get("target",""))')"
    [[ -n "$reset_path" ]] || die "Server BMC ${HOST_BMC_IP} (${HOST_BMC_NAME}) has no Redfish reset action"
    log "Power-cycling server chassis ${HOST_BMC_NAME} (${HOST_BMC_IP})"
    response="$(host_bmc_redfish POST "https://${HOST_BMC_IP}${reset_path}" '{"ResetType":"PowerCycle"}')"
    code="$(host_bmc_redfish_code "$response")"
    [[ "$code" =~ ^2 ]] || die "PowerCycle request to server BMC ${HOST_BMC_IP} (${HOST_BMC_NAME}) returned HTTP ${code}"
  done
  wait_zero_trust_dpu_bmcs_reachable "the chassis power cycle"
}

# Names of DPUNodes currently annotated
# provisioning.dpu.nvidia.com/dpunode-external-reboot-required=true.
list_zero_trust_external_reboot_pending() {
  oc get dpunodes.provisioning.dpu.nvidia.com -n dpf-operator-system -o json 2>/dev/null |
    python3 -c '
import json, sys
data = json.load(sys.stdin)
for item in data.get("items", []):
    annotations = item.get("metadata", {}).get("annotations") or {}
    if annotations.get("provisioning.dpu.nvidia.com/dpunode-external-reboot-required") == "true":
        print(item["metadata"]["name"])
' 2>/dev/null || true
}

# Automates the manual step from the README: power-cycle the chassis, then
# clear the dpunode-external-reboot-required annotation. Every DPUNode shares
# the same chassis fleet (WORKER_COUNT/BMC_*), so one pending DPUNode powers
# every chassis rather than trying to map a DPU to the one host it sits in.
#
# Without --force, this only acts when ZT_AUTO_POWER_CYCLE=true; otherwise it
# falls back to printing the manual instructions, unchanged from before this
# automation existed.
wait_zero_trust_external_reboots() {
  local force=false
  [[ "${1:-}" == "--force" ]] && force=true

  if [[ "$force" != true && "${ZT_AUTO_POWER_CYCLE:-false}" != "true" ]]; then
    print_zero_trust_next_steps
    return 0
  fi

  command -v oc >/dev/null 2>&1 || die "oc is required to automate the Zero Trust external reboot step"
  log "Watching for DPUs that need an external power cycle (up to ${WAIT_EXTERNAL_REBOOT}s)"

  local start=$SECONDS pending dpu_node handled_any=false
  while true; do
    pending="$(list_zero_trust_external_reboot_pending)"

    if [[ -z "$pending" ]]; then
      if ((SECONDS - start >= WAIT_EXTERNAL_REBOOT)); then
        log "No DPUNode has requested an external reboot within ${WAIT_EXTERNAL_REBOOT}s; nothing more to do"
        return 0
      fi
      if [[ "$handled_any" == true ]]; then
        log "No DPUNodes are waiting on an external reboot anymore"
        return 0
      fi
      sleep 15
      continue
    fi

    log "DPUNode(s) requesting an external reboot: $(tr '\n' ' ' <<<"$pending")"
    power_cycle_zero_trust_hosts

    while IFS= read -r dpu_node; do
      [[ -n "$dpu_node" ]] || continue
      log "Clearing dpunode-external-reboot-required on ${dpu_node}"
      oc -n dpf-operator-system annotate dpunode "$dpu_node" \
        provisioning.dpu.nvidia.com/dpunode-external-reboot-required- --overwrite
    done <<<"$pending"
    handled_any=true
    start=$SECONDS
  done
}

# Waits until `oc get <kind> <name> -n dpf-operator-system` succeeds.
wait_for_named() {
  local kind="$1" name="$2" timeout_s="$3"
  local start=$SECONDS
  log "Waiting up to ${timeout_s}s for ${kind}/${name} in dpf-operator-system"
  while ! oc get "$kind" "$name" -n dpf-operator-system >/dev/null 2>&1; do
    if ((SECONDS - start >= timeout_s)); then
      die "Timed out waiting for ${kind}/${name} in dpf-operator-system"
    fi
    sleep 10
  done
}

# Publishes the BFB on ZT_BFB_REGISTRY_PORT and tells Redfish to use it.
# The Service is ours, with a fixed NodePort, and selects the operator's
# bfb-registry pods. The operator's own Service is left alone: recreating it
# assigns a new NodePort and would strand an in-progress download.
configure_zero_trust_bfb_registry() {
  local api_ip address got endpoint
  wait_for_named service bfb-registry "$WAIT_MEDIUM"
  apply_manifest "$(manifest dpf/zero-trust/bfb-registry-nodeport.yaml)"
  endpoint="$(oc get endpoints bfb-registry-bmc -n dpf-operator-system -o jsonpath='{.subsets[0].addresses[0].ip}' 2>/dev/null || true)"
  [[ -n "$endpoint" ]] || die "Service bfb-registry-bmc has no endpoints. The bfb-registry pod is not ready."
  api_ip="$(getent ahostsv4 "$HOST_CLUSTER_API" 2>/dev/null | awk 'NR == 1 { print $1 }')"
  [[ "$api_ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || die "Could not resolve ${HOST_CLUSTER_API} to an IPv4 address for the BFB registry"
  address="http://${api_ip}:${ZT_BFB_REGISTRY_PORT}"
  log "Pointing Redfish at the BFB registry ${address}"
  oc patch dpfoperatorconfig dpfoperatorconfig -n dpf-operator-system --type=merge \
    -p "{\"spec\":{\"provisioningController\":{\"registry\":{\"loadBalancerAddress\":\"${address}\"}}}}"
  got="$(oc get dpfoperatorconfig dpfoperatorconfig -n dpf-operator-system -o jsonpath='{.spec.provisioningController.registry.loadBalancerAddress}')"
  [[ "$got" == "$address" ]] || die "BFB registry address is '${got}', expected '${address}'"
}

# Applies the DPU inventory (DPUDiscovery for scanning, or DPUDevice+DPUNode
# per serial for static), then waits for DPF to register each configured DPU
# and normalizes the DPUNode label DPUDeployment selects on.
configure_zero_trust_dpu_inventory() {
  local serial_var serial

  if [[ "$ZT_DPU_DISCOVERY_MODE" == "scanning" ]]; then
    log "Applying DPUDiscovery ${ZT_DPU_DISCOVERY_NAME} (scanning ${ZT_DPU_BMC_IP_RANGE_START}-${ZT_DPU_BMC_IP_RANGE_END})"
    apply_manifest "$(manifest dpf/zero-trust/dpudiscovery.yaml)"
  else
    log "Applying static Zero Trust DPUDevice/DPUNode inventory"
    while IFS= read -r serial_var; do
      serial="${!serial_var}"
      [[ -n "$serial" ]] || continue
      use_dpu "$serial_var"
      apply_manifest "$(manifest dpf/zero-trust/dpudevice.yaml)"
      apply_manifest "$(manifest dpf/zero-trust/dpunode.yaml)"
    done < <(list_dpu_serial_variables)
  fi

  while IFS= read -r serial_var; do
    serial="${!serial_var}"
    [[ -n "$serial" ]] || continue
    wait_for_named dpudevices.provisioning.dpu.nvidia.com "$serial" "$WAIT_MEDIUM"
    wait_for_named dpunodes.provisioning.dpu.nvidia.com "dpu-node-${serial}" "$WAIT_MEDIUM"
    log "Normalizing the DPUNode label for dpu-node-${serial}"
    oc label dpunode.provisioning.dpu.nvidia.com "dpu-node-${serial}" -n dpf-operator-system \
      feature.node.kubernetes.io/dpu-enabled= --overwrite
  done < <(list_dpu_serial_variables)

  oc get dpudevices.provisioning.dpu.nvidia.com -n dpf-operator-system
  oc get dpunodes.provisioning.dpu.nvidia.com -n dpf-operator-system
}

kube_apiserver_clusteroperator_healthy() {
  local avail prog degr
  avail=$(oc get clusteroperator kube-apiserver -o jsonpath='{.status.conditions[?(@.type=="Available")].status}' 2>/dev/null || true)
  prog=$(oc get clusteroperator kube-apiserver -o jsonpath='{.status.conditions[?(@.type=="Progressing")].status}' 2>/dev/null || true)
  degr=$(oc get clusteroperator kube-apiserver -o jsonpath='{.status.conditions[?(@.type=="Degraded")].status}' 2>/dev/null || true)
  [[ "$avail" == "True" && "$prog" == "False" && "$degr" == "False" ]]
}

# Zero Trust DPUs bootstrap-join the hosted cluster with a kube-apiserver
# bootstrap token rather than a host-signed CSR. This patch is cluster-wide
# and triggers a kube-apiserver rollout; it is applied once and left in place.
apply_zero_trust_bootstrap_auth() {
  local patch_file enabled
  patch_file="$(manifest dpf/zero-trust/kube-apiserver-bootstrap-auth.patch.yaml)"
  enabled=$(oc get kubeapiserver cluster \
    -o 'jsonpath={.spec.unsupportedConfigOverrides.apiServerArguments.enable-bootstrap-token-auth[0]}' \
    2>/dev/null || true)

  if [[ "$enabled" == "true" ]]; then
    log "kube-apiserver bootstrap-token authentication is already enabled"
    return 0
  fi

  log "Enabling kube-apiserver bootstrap-token authentication for Zero Trust DPU agents"
  oc patch kubeapiserver cluster --type=merge --patch-file "$patch_file"

  log "Waiting up to ${WAIT_HOSTED}s for the kube-apiserver ClusterOperator rollout"
  local start=$SECONDS
  while ! kube_apiserver_clusteroperator_healthy; do
    if ((SECONDS - start >= WAIT_HOSTED)); then
      oc get clusteroperator kube-apiserver || true
      die "kube-apiserver rollout did not complete after enabling bootstrap-token authentication"
    fi
    sleep 15
  done
  log "kube-apiserver ClusterOperator is healthy"
}

# Builds the perDPUValuesYAML block (hostnamePattern + vlan/AS per DPU) that
# the Zero Trust HBN DPUServiceConfiguration template substitutes via
# ${DPU_VALUES}. DPU<n> gets VLANs (10+n)/(20+n) and AS 65001+(n*100), e.g.
# DPU1 -> VLANs 11/21, AS 65101; DPU2 -> VLANs 12/22, AS 65201.
build_zero_trust_dpu_values() {
  local serial_var serial index vlan1 vlan2 autonomous_system out=""
  while IFS= read -r serial_var; do
    serial="${!serial_var}"
    [[ -n "$serial" ]] || continue
    index="${serial_var#DPU}"
    index="${index%_SERIAL}"
    vlan1=$((10 + index))
    vlan2=$((20 + index))
    autonomous_system=$((65001 + (index * 100)))
    out+="            - hostnamePattern: \"dpu-node-${serial}*\"
              values:
                vlan1: ${vlan1}
                vlan2: ${vlan2}
                bgp_autonomous_system: ${autonomous_system}
"
  done < <(list_dpu_serial_variables)
  printf '%s' "$out"
}

# Best-effort, non-fatal: warns (does not fail preflight) if a configured DPU
# BMC Redfish endpoint doesn't answer. Skipped for scanning mode, where BMC
# IPs aren't known individually, and silently skipped if curl is unavailable.
check_zero_trust_bmc_reachability() {
  [[ "$ZT_DPU_DISCOVERY_MODE" == "static" ]] || return 0
  command -v curl >/dev/null 2>&1 || return 0

  local serial_var serial bmc_ip_var bmc_ip
  while IFS= read -r serial_var; do
    serial="${!serial_var}"
    [[ -n "$serial" ]] || continue
    bmc_ip_var="${serial_var%_SERIAL}_BMC_IP"
    bmc_ip="${!bmc_ip_var:-}"
    [[ -n "$bmc_ip" ]] || continue
    if curl -k -u "root:${ZT_DPU_BMC_ROOT_PASSWORD}" -s -o /dev/null -f \
      --connect-timeout 5 --max-time 10 \
      "https://${bmc_ip}/redfish/v1/Systems/Bluefield"; then
      log "DPU ${serial} Redfish endpoint ${bmc_ip} is reachable"
    else
      log "WARNING: DPU ${serial} Redfish endpoint ${bmc_ip} did not answer. 'make dpf' powers on the server chassis before provisioning. Confirm rshim is enabled and the shared root password is correct."
    fi
  done < <(list_dpu_serial_variables)
}

print_zero_trust_next_steps() {
  local dpu_node
  local dpu_nodes=()
  while IFS= read -r dpu_node; do
    [[ -n "$dpu_node" ]] || continue
    dpu_nodes+=("$dpu_node")
  done < <(oc get dpunodes.provisioning.dpu.nvidia.com -n dpf-operator-system \
    -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' 2>/dev/null || true)

  printf '\n'
  printf '%s\n' "================================================================================"
  printf '%s\n' "DPU provisioning is running in the background - manual action may be required"
  printf '%s\n' "================================================================================"
  printf '%s\n' "Monitor progress:"
  printf '%s\n' "  oc get dpu -A -w"
  printf '\n'
  printf '%s\n' "For each DPU that reaches the Rebooting phase:"
  printf '%s\n' "  1. Manually power-cycle the corresponding bare-metal host."
  printf '%s\n' "  2. After the DPU is back up, clear the external-reboot annotation:"
  if ((${#dpu_nodes[@]} > 0)); then
    for dpu_node in "${dpu_nodes[@]}"; do
      printf '     oc -n dpf-operator-system annotate dpunode %s \\\n' "$dpu_node"
      printf '       provisioning.dpu.nvidia.com/dpunode-external-reboot-required-\n'
    done
  else
    printf '     oc -n dpf-operator-system annotate dpunode <dpunode-name> \\\n'
    printf '       provisioning.dpu.nvidia.com/dpunode-external-reboot-required-\n'
  fi
  printf '%s\n' "================================================================================"
}

load_env
apply_derived
build_envsubst_format
