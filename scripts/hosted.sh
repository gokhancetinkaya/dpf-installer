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
helm_upgrade dpf-hcp-provisioner-operator \
  "$DPF_HCP_PROVISIONER_CHART" \
  --registry-config "$OPENSHIFT_PULL_SECRET" \
  --version "$DPF_HCP_PROVISIONER_VERSION" \
  --namespace dpf-hcp-provisioner-system \
  --create-namespace \
  --set provisionerConfig.manageDPUServiceTemplates=true \
  --wait \
  --timeout "$HELM_TIMEOUT"

oc get pods -n dpf-hcp-provisioner-system
oc get dpfhcpprovisionerconfigs.provisioning.dpu.hcp.io default -o yaml || true

oc apply -f - <<EOF
apiVersion: v1
kind: Namespace
metadata:
  name: ${CLUSTERS_NAMESPACE}
EOF

log "Creating pull-secret and SSH key secrets in ${CLUSTERS_NAMESPACE}"
apply_secret "$CLUSTERS_NAMESPACE" generic "$PULL_SECRET_NAME" \
  --from-file=.dockerconfigjson="$OPENSHIFT_PULL_SECRET" \
  --type=kubernetes.io/dockerconfigjson
apply_secret "$CLUSTERS_NAMESPACE" generic "$SSH_KEY_SECRET_NAME" \
  --from-file=id_rsa.pub="$SSH_KEY"

apply_manifest "$(manifest hosted/dpucluster.yaml)"
apply_manifest "$(manifest hosted/dpfhcpprovisioner.yaml)"

log "Waiting up to ${WAIT_HOSTED}s for DPFHCPProvisioner ${HOSTED_CLUSTER_NAME} to become Ready"
oc wait "dpfhcpprovisioner/${HOSTED_CLUSTER_NAME}" -n "$CLUSTERS_NAMESPACE" \
  --for=jsonpath='{.status.phase}'=Ready \
  --timeout="${WAIT_HOSTED}s"
oc get dpfhcpprovisioner -n "$CLUSTERS_NAMESPACE"
oc get dpucluster "$HOSTED_CLUSTER_NAME" -n dpf-operator-system
log "Hosted cluster provisioner is Ready"
