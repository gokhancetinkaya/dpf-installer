SHELL := /bin/bash
ROOT := $(dir $(abspath $(lastword $(MAKEFILE_LIST))))

.DEFAULT_GOAL := help
.PHONY: help check render install preflight platform cluster-prep dpf dpu-services hosted injector workers hosted-scc observability status check-doc-drift browse-doc-drift

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
		'  check-doc-drift   check marked code against the OpenShift DPF docs' \
		'  browse-doc-drift  browse doc drift in the asadoc review UI' \
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

# asadoc release used by check-doc-drift, downloaded into .bin/ on first use.
# Use your own build instead with: make check-doc-drift ASADOC=asadoc
ASADOC_VERSION ?= v0.9.0
ASADOC ?= .bin/asadoc-$(ASADOC_VERSION)
# CI passes --format=github for a job summary and annotations
ASADOC_CHECK_FLAGS ?=
# Release target triple for this machine, e.g. aarch64-apple-darwin on an Apple Silicon Mac
ASADOC_TARGET ?= $(subst arm64,aarch64,$(shell uname -m))-$(if $(filter Darwin,$(shell uname -s)),apple-darwin,unknown-linux-musl)

.bin/asadoc-%:
	@mkdir -p .bin
	@echo "Downloading asadoc $* for $(ASADOC_TARGET)..."
	@curl -sSfL -o $@.tar.gz https://github.com/omertuc/asadoc/releases/download/$*/asadoc-$(ASADOC_TARGET).tar.gz \
		|| { rm -f $@.tar.gz; echo "Couldn't download asadoc $* for $(ASADOC_TARGET): see https://github.com/omertuc/asadoc/releases"; exit 1; }
	@tar -xzOf $@.tar.gz asadoc > $@.tmp && rm $@.tar.gz && chmod +x $@.tmp && mv $@.tmp $@

check-doc-drift: $(filter .bin/%,$(ASADOC))
	@$(ASADOC) check $(ASADOC_CHECK_FLAGS)

browse-doc-drift: $(filter .bin/%,$(ASADOC))
	@$(ASADOC) serve
