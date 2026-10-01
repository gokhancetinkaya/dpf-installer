# OpenShift DPF installer

Installer for NVIDIA DOCA Platform Framework (DPF) on an existing OpenShift management cluster with NVIDIA BlueField-3 DPUs.

It does not create the management cluster. Point it at a cluster that is already installed, fill in `.env`, and run `make install`. The install is phased and safe to re-run.

`make install` prepares the management cluster, installs the DPF operator and DPU services, creates a hosted control plane for the DPU cluster, installs the OVN-Kubernetes VF resource injector, and provisions the first DPU worker nodes. Dashboards are a separate step.

## Prerequisites

On the machine that runs the installer:

- `oc`
- Helm 3
- `envsubst` (from gettext)

On the management cluster:

- A bare-metal OpenShift cluster, with the `openshift-machine-api` namespace
- A storage class for hosted etcd (the example uses `lvms-vg1`)
- Hosted control planes available through the multicluster engine (`multiclusterengine/mce`), with the Hypershift component enabled
- The Node Feature Discovery operator already installed
- A virtual IP for the hosted cluster API

You also need:

- A kubeconfig for the management cluster
- A Red Hat pull secret (`openshift-pull-secret.json` from the Red Hat console)
- An SSH public key for the hosted cluster
- BMC address, credentials, boot MAC, and root device for each DPU worker you want this installer to provision

The versions in `.env.example` target OpenShift 4.22 and DPF v26.4.1, including the `dpu-worker-config` and `dpf-hcp-provisioner` charts from `registry.redhat.io`.

## Configure

```bash
cp .env.example .env
```

Edit `.env`. Use `KEY=value` lines with no inline comments. Paths may be absolute, or relative to this directory.

Set at least:

| Variable | Purpose |
| --- | --- |
| `KUBECONFIG` | Management cluster kubeconfig |
| `OPENSHIFT_PULL_SECRET` | Path to the Red Hat pull secret |
| `SSH_KEY` | Path to the SSH public key |
| `CLUSTER_NAME`, `BASE_DOMAIN` | Used to derive `api.${CLUSTER_NAME}.${BASE_DOMAIN}` when `HOST_CLUSTER_API` is empty |
| `HOSTED_CLUSTER_VIP` | API virtual IP for the hosted cluster |
| `BMC_IP`, `BMC_USER`, `BMC_PASSWORD`, `BOOT_MAC`, `ROOT_DEVICE` | First DPU worker |

Set `WORKER_COUNT=0` to skip BareMetalHost provisioning. For more than one worker, set `WORKER_COUNT` and add `WORKER_2_*`, `WORKER_3_*`, and so on, using the same field names as the first worker.

`.env` is gitignored. It holds pull-secret paths and BMC credentials. Do not commit it.

Check that the manifests render and the required values are set:

```bash
make check
```

## Install

```bash
make install
```

That runs preflight through workers. When it finishes, install the dashboards if you want them:

```bash
make observability
make status
```

`make status` prints nodes, DPF pods, DPUs, DPU services, the hosted provisioner, and BareMetalHosts.

Each phase can be run on its own, and each one is safe to re-run:

| Target | What it does |
| --- | --- |
| `make preflight` | Checks tools, kubeconfig, NFD, and Hypershift |
| `make platform` | Installs dpu-worker-config, cert-manager, MetalLB, OpenShift GitOps, and the maintenance operator |
| `make cluster-prep` | Configures NFD and MetalLB, creates the Argo CD instance, and enables global IP forwarding |
| `make dpf` | Installs the DPF operator and applies `DPFOperatorConfig` |
| `make dpu-services` | Applies the BFB, flavor, `DPUDeployment`, and HBN, OVN-Kubernetes, and DOCA Telemetry configuration |
| `make hosted` | Installs the HCP provisioner, creates secrets and the `DPUCluster`, and waits until the provisioner is Ready |
| `make injector` | Installs the OVN-Kubernetes VF resource injector |
| `make workers` | Creates BareMetalHosts, approves CSRs, applies the hosted SCC, and waits until the worker is Ready |
| `make observability` | Enables user-workload monitoring and a DOCA Telemetry dashboard |

## Layout

- `manifests/` holds the manifests. Files that contain `${VAR}` are rendered with `envsubst` at apply time.
- `scripts/` holds one script per phase. Shared helpers are in `scripts/lib.sh`.
- `generated/` is gitignored. Rendered manifests and other local output go there.

`make render` writes the rendered manifests to `generated/manifests` without applying them.

## Docs drift

Much of this code is also in the OpenShift DPF docs. Lines marked with `# @code-as-a-doc:` comments are checked against the docs' code blocks by [asadoc](https://github.com/omertuc/asadoc), configured in `.asadoc/config.toml`. If you change marked code, run:

```bash
make check-doc-drift
```

`make browse-doc-drift` opens the same results in a web UI. CI runs the check on every pull request.
