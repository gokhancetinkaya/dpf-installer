SHELL := /bin/bash
ROOT := $(dir $(abspath $(lastword $(MAKEFILE_LIST))))

.DEFAULT_GOAL := help
.PHONY: help check render install preflight platform cluster-prep dpf dpu-services hosted injector workers hosted-scc observability status

help:
	@printf '%s\n' \
		'DPF installer for an existing OpenShift management cluster.' \
		'' \
		'Setup:' \
		'  cp .env.example .env    # then edit lab values' \
		'  make check              # render manifests and verify substitution' \
		'  make install            # run every phase through workers' \
		'' \
		'Phases (safe to re-run):' \
		'  preflight       tools, kubeconfig, NFD, Hypershift' \
		'  platform        dpu-worker-config, cert-manager, MetalLB, GitOps, maintenance-operator' \
		'  cluster-prep    NFD, MetalLB, Argo CD, global IP forwarding' \
		'  dpf             dpf-operator and DPFOperatorConfig' \
		'  dpu-services    flavor, BFB, DPUDeployment, HBN, OVN, DTS, IPAM' \
		'  hosted          HCP provisioner, secrets, DPUCluster, wait until Ready' \
		'  injector        OVN-Kubernetes VF resource injector' \
		'  workers         BareMetalHost, CSR approval, hosted SCC, then wait until Ready' \
		'  observability   user-workload monitoring, console dashboard, Grafana' \
		'' \
		'Other:' \
		'  hosted-scc      apply the hosted SCC by itself; make install does this from workers' \
		'  render          write rendered manifests to generated/manifests' \
		'  status          read-only summary of nodes, DPUs, and the hosted provisioner' \
		'  install         preflight through workers (observability is separate)'

check:
	bash "$(ROOT)scripts/check-render.sh"

render:
	bash "$(ROOT)scripts/render.sh"

install:
	bash "$(ROOT)scripts/install.sh"

preflight:
	bash "$(ROOT)scripts/preflight.sh"

platform:
	bash "$(ROOT)scripts/platform.sh"

cluster-prep:
	bash "$(ROOT)scripts/cluster-prep.sh"

dpf:
	bash "$(ROOT)scripts/dpf.sh"

dpu-services:
	bash "$(ROOT)scripts/dpu-services.sh"

hosted:
	bash "$(ROOT)scripts/hosted.sh"

injector:
	bash "$(ROOT)scripts/injector.sh"

workers:
	bash "$(ROOT)scripts/workers.sh"

hosted-scc:
	bash "$(ROOT)scripts/hosted-scc.sh"

observability:
	bash "$(ROOT)scripts/observability.sh"

status:
	bash "$(ROOT)scripts/status.sh"
