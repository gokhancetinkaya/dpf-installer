#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

log "Phase: hosted"
require_cmds oc helm envsubst
require_vars \
  OPENSHIFT_PULL_SECRET SSH_KEY \
  DPF_HCP_PROVISIONER_CHART DPF_HCP_PROVISIONER_VERSION \
  HOSTED_CLUSTER_NAME CLUSTERS_NAMESPACE BASE_DOMAIN \
  ETCD_STORAGE_CLASS OCP_RELEASE_IMAGE \
  PULL_SECRET_NAME SSH_KEY_SECRET_NAME HOSTED_CLUSTER_VIP
require_cluster
check_hypershift

log "Installing dpf-hcp-provisioner ${DPF_HCP_PROVISIONER_VERSION}"
# @code-as-a-doc: start section "dpf-hcp-provisioner-install"
#   | remove-prefix: "helm_upgrade " | doc remove-prefix: "$ helm upgrade --install "
#   | TODO: "helm_upgrade is helm upgrade --install plus --force-conflicts (Helm 4) and --timeout; an asadoc option that maps a code command to the doc's would replace both remove-prefix options"
#   | remove-lines-starting-with: "--wait"
#   | TODO: "The docs don't pass --wait, so the next step can run before the chart is ready; add --wait to the docs"
#   | reindent: 2 -> 4
#   | TODO: "The docs indent continuation lines by 4 here and by 2 in their maintenance-operator and injector commands; use 2 throughout the docs"
#   | param: "\"$*\""
helm_upgrade dpf-hcp-provisioner-operator \
  "$DPF_HCP_PROVISIONER_CHART" \
  --wait \
  --registry-config "$OPENSHIFT_PULL_SECRET" \
  --version "$DPF_HCP_PROVISIONER_VERSION" \
  --namespace dpf-hcp-provisioner-system \
  --create-namespace \
  --set provisionerConfig.manageDPUServiceTemplates=true
# @code-as-a-doc: end section "dpf-hcp-provisioner-install"

oc get pods -n dpf-hcp-provisioner-system
oc get dpfhcpprovisionerconfigs.provisioning.dpu.hcp.io default -o yaml || true

oc apply -f - <<EOF
apiVersion: v1
kind: Namespace
metadata:
  name: ${CLUSTERS_NAMESPACE}
EOF

log "Creating pull-secret and SSH key secrets in ${CLUSTERS_NAMESPACE}"
# @code-as-a-doc: start section "hcp-pull-secret"
#   | remove-prefix: "apply_secret " | doc remove-prefix: "$ oc create secret "
#   | TODO: "apply_secret is oc create secret made rerunnable (--dry-run=client piped to oc apply); an asadoc option that maps a code command to the doc's would replace both remove-prefix options"
#   | reindent: 2 -> 4
#   | TODO: "The docs indent continuation lines by 4 here and by 2 in their maintenance-operator and injector commands; use 2 throughout the docs"
#   | param: "\"$*\""
apply_secret generic "$PULL_SECRET_NAME" \
  --from-file=.dockerconfigjson="$OPENSHIFT_PULL_SECRET" \
  --type=kubernetes.io/dockerconfigjson \
  -n "$CLUSTERS_NAMESPACE"
# @code-as-a-doc: end section "hcp-pull-secret"
# @code-as-a-doc: start section "hcp-ssh-key-secret"
#   | remove-prefix: "apply_secret " | doc remove-prefix: "$ oc create secret "
#   | TODO: "apply_secret is oc create secret made rerunnable (--dry-run=client piped to oc apply); an asadoc option that maps a code command to the doc's would replace both remove-prefix options"
#   | reindent: 2 -> 4
#   | TODO: "The docs indent continuation lines by 4 here and by 2 in their maintenance-operator and injector commands; use 2 throughout the docs"
#   | param: "\"$*\""
apply_secret generic "$SSH_KEY_SECRET_NAME" \
  --from-file=id_rsa.pub="$SSH_KEY" \
  --type=Opaque \
  -n "$CLUSTERS_NAMESPACE"
# @code-as-a-doc: end section "hcp-ssh-key-secret"

apply_manifest "$(manifest hosted/dpucluster.yaml)"
apply_manifest "$(manifest hosted/dpfhcpprovisioner.yaml)"

log "Waiting up to ${WAIT_HOSTED}s for DPFHCPProvisioner ${HOSTED_CLUSTER_NAME} to become Ready"
oc wait "dpfhcpprovisioner/${HOSTED_CLUSTER_NAME}" -n "$CLUSTERS_NAMESPACE" \
  --for=jsonpath='{.status.phase}'=Ready \
  --timeout="${WAIT_HOSTED}s"
oc get dpfhcpprovisioner -n "$CLUSTERS_NAMESPACE"
oc get dpucluster "$HOSTED_CLUSTER_NAME" -n dpf-operator-system
log "Hosted cluster provisioner is Ready"
