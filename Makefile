SHELL := /bin/bash
ROOT := $(dir $(abspath $(lastword $(MAKEFILE_LIST))))

.DEFAULT_GOAL := help
.PHONY: help check render install preflight platform cluster-prep dpf dpu-services hosted injector workers hosted-scc observability status external-reboot

help:
	@printf '%s\n' \
		'DPF installer for an existing OpenShift management cluster.' \
		'' \
		'Setup:' \
		'  cp .env.example .env    # then edit lab values' \
		'  make check              # render manifests and verify substitution' \
		'  make install            # run every phase for the selected DPF_DEPLOYMENT_MODE' \
		'' \
		'DPF_DEPLOYMENT_MODE in .env selects how DPUs are provisioned:' \
		'  host-trusted (default)  physical server joins as an OpenShift node (BareMetalHost);' \
		'                          DPF configures the embedded DPU through that trusted host' \
		'  zero-trust               DPF never trusts the host OS; it provisions every DPU directly' \
		'                           over its own BMC/Redfish. See README.md before using it.' \
		'                           make install then skips the injector and workers phases.' \
		'' \
		'Phases (safe to re-run):' \
		'  preflight       tools, kubeconfig, NFD, Hypershift, Zero Trust config validation' \
		'  platform        dpu-worker-config, cert-manager, MetalLB, GitOps, maintenance-operator' \
		'  cluster-prep    NFD, MetalLB, Argo CD, global IP forwarding' \
		'  dpf             dpf-operator, DPFOperatorConfig; Zero Trust: bootstrap-token auth,' \
		'                  BMC secret, DPUDiscovery/DPUDevice/DPUNode inventory' \
		'  dpu-services    flavor, BFB, DPUDeployment, HBN, OVN, DTS, IPAM (host-trusted);' \
		'                  flavor, BFB, DPUDeployment, HBN-only chain, IPAM (zero-trust)' \
		'  hosted          HCP provisioner, secrets, DPUCluster, wait until Ready' \
		'  injector        OVN-Kubernetes VF resource injector (host-trusted only)' \
		'  workers         BareMetalHost, CSR approval, hosted SCC, then wait until Ready (host-trusted only)' \
		'  observability   user-workload monitoring, console dashboard, Grafana' \
		'' \
		'Other:' \
		'  hosted-scc      apply the hosted SCC by itself; make install does this from workers' \
		'                  (host-trusted) or right after hosted (zero-trust)' \
		'  external-reboot Zero Trust only: power-cycle every chassis and clear the' \
		'                  dpunode-external-reboot-required annotation for any DPUNode that' \
		'                  needs it right now. make install does this automatically when' \
		'                  ZT_AUTO_POWER_CYCLE=true; use this target to run it by hand' \
		'                  otherwise, or to resume an install left waiting on it.' \
		'  render          write rendered manifests to generated/manifests' \
		'  status          read-only summary of nodes, DPUs, and the hosted provisioner' \
		'  install         preflight through the phases for the selected DPF_DEPLOYMENT_MODE' \
		'' \
		'Skip phases (e.g. for testing partial flows without all prerequisites):' \
		'  make install SKIP_PHASES=preflight' \
		'  make install SKIP_PHASES=preflight,platform'

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

external-reboot:
	bash "$(ROOT)scripts/external-reboot.sh"
