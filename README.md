# OpenShift DPF installer

Installer for NVIDIA DOCA Platform Framework (DPF) on an existing OpenShift management cluster with NVIDIA BlueField-3 DPUs.

It does not create the management cluster. Point it at a cluster that is already installed, fill in `.env`, and run `make install`. The install is phased and safe to re-run.

`make install` prepares the management cluster, installs the DPF operator and DPU services, and creates a hosted control plane for the DPU cluster. In the default `host-trusted` mode it also installs the OVN-Kubernetes VF resource injector and provisions the first DPU worker nodes as `BareMetalHost`s. In `zero-trust` mode (see below) DPF provisions DPUs directly over Redfish instead, so those two phases are skipped. Dashboards are a separate step.

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
| `make preflight` | Checks tools, kubeconfig, NFD, and Hypershift; in `zero-trust` mode also validates the Zero Trust configuration |
| `make platform` | Installs dpu-worker-config, cert-manager, MetalLB, OpenShift GitOps, and the maintenance operator |
| `make cluster-prep` | Configures NFD and MetalLB, creates the Argo CD instance, and enables global IP forwarding |
| `make dpf` | Installs the DPF operator and applies `DPFOperatorConfig`; in `zero-trust` mode also powers on each server chassis through its BMC, publishes the BFB registry on `ZT_BFB_REGISTRY_PORT`, enables kube-apiserver bootstrap-token auth, and applies the DPU inventory (`DPUDiscovery` or `DPUDevice`/`DPUNode`) |
| `make dpu-services` | Applies the BFB, flavor, `DPUDeployment`, and HBN, OVN-Kubernetes, and DOCA Telemetry configuration (`host-trusted`), or the BFB, Zero Trust flavor, `DPUDeployment`, and HBN-only dual-VRF chain (`zero-trust`) |
| `make hosted` | Installs the HCP provisioner, creates secrets and the `DPUCluster`, and waits until the provisioner is Ready |
| `make injector` | Installs the OVN-Kubernetes VF resource injector (`host-trusted` only; refuses in `zero-trust`) |
| `make workers` | Creates BareMetalHosts, approves CSRs, applies the hosted SCC, and waits until the worker is Ready (`host-trusted` only; refuses in `zero-trust`) |
| `make observability` | Enables user-workload monitoring and a DOCA Telemetry dashboard |

## Zero Trust mode

`DPF_DEPLOYMENT_MODE` in `.env` selects how DPUs are provisioned:

- `host-trusted` (default): the physical server joins the management cluster
  as an OpenShift node through `BareMetalHost`, and DPF configures the
  embedded DPU through that trusted host OS.
- `zero-trust`: DPF never trusts the host OS. It provisions every DPU
  directly over the DPU's own BMC/Redfish, and the DPU joins the hosted
  cluster using a kube-apiserver bootstrap token instead of a host-signed
  CSR. NVIDIA's Zero Trust documentation also caps `controlPlaneMTU` at
  1500, independent of the 9000 high-speed/data-plane MTU (`NODES_MTU`);
  `ZT_CONTROL_PLANE_MTU` (default `1500`) controls this and must not be
  raised above `1500`. `make install` skips the `injector` and `workers`
  phases in this mode:
  there is no `BareMetalHost` and no OVN-Kubernetes DPU service to inject VF
  resources for. The v1 Zero Trust service chain is HBN-only (dual-VRF BGP
  EVPN over the two uplinks and the host-facing port); it does not deploy
  OVN-Kubernetes or DOCA Telemetry Service.

### Zero Trust DPU BMC prerequisites

Complete these manual steps on every DPU BMC before setting
`DPF_DEPLOYMENT_MODE=zero-trust` and running `make install`:

1. Configure the same `root` password on every DPU BMC. Set
   `ZT_DPU_BMC_ROOT_PASSWORD` to this password in `.env`.
2. Enable and start the `rshim` service on every DPU BMC:

   ```bash
   ssh root@<DPU_BMC_IP>
   systemctl enable rshim
   systemctl start rshim
   systemctl is-enabled rshim
   systemctl is-active rshim
   ```

   The last two commands must report `enabled` and `active`.
3. Verify that the BMC Redfish endpoint is reachable (this prompts for the
   shared `root` password instead of putting it in the shell history):

   ```bash
   curl -k -u root https://<DPU_BMC_IP>/redfish/v1/Systems/Bluefield
   ```

4. Select a DPU inventory mode with `ZT_DPU_DISCOVERY_MODE`:
   - `scanning` (default): set `ZT_DPU_BMC_IP_RANGE_START` and
     `ZT_DPU_BMC_IP_RANGE_END`. DPF scans the inclusive range over Redfish
     and creates the `DPUDevice` and `DPUNode` resources itself. Gaps in the
     range are fine (for example, a range from `.3` through `.8` can contain
     DPUs only at `.3`, `.6`, and `.8`; every address in the range is still
     scanned). `DPU1_BMC_IP` and friends are not needed in this mode, but you
     still set `DPU1_SERIAL` (and `DPU2_SERIAL`, ...) so the installer knows
     which discovered DPUs to wait for.
   - `static`: pair every DPU serial with its BMC address, for example
     `DPU1_SERIAL=mt2437600n0p` and `DPU1_BMC_IP=10.6.136.33`. The installer
     creates a dedicated `DPUDevice` and `DPUNode` for each numbered pair.
     Serials must be lowercase; they are upper-cased automatically for
     `DPUDevice.spec.serialNumber`. Add `DPU2_SERIAL`/`DPU2_BMC_IP`,
     `DPU3_SERIAL`/`DPU3_BMC_IP`, ... for more DPUs.

   To read a DPU's serial number in lowercase:

   ```bash
   curl -k -u root:'BMC root password' https://<DPU_BMC_IP>/redfish/v1/Systems/Bluefield \
     | jq -r '.SerialNumber | ascii_downcase'
   ```

5. Confirm the DPU BMC network can reach the address `HOST_CLUSTER_API`
   resolves to on `ZT_BFB_REGISTRY_PORT` (default `30806`). `make dpf` creates
   a Service that listens on that fixed NodePort and points Redfish at
   `http://<that address>:<ZT_BFB_REGISTRY_PORT>`. The port must be in the
   cluster NodePort range, `30000-32767`.
6. Keep `WORKER_COUNT` and the server BMC address, user, and password set.
   `make dpf` uses that BMC to power on the chassis the DPU is plugged into.
   It does not create a `BareMetalHost`. `BOOT_MAC` and `ROOT_DEVICE` are
   unused in this mode.

### Running Zero Trust

```bash
# in .env:
DPF_DEPLOYMENT_MODE=zero-trust
NODES_MTU=9000   # required in Zero Trust mode
# WORKER_COUNT and BMC_IP/BMC_USER/BMC_PASSWORD stay set. They power the
# server chassis. Zero Trust does not create a BareMetalHost.

make check
make install
```

Some DPU firmware/NVConfig changes only take effect after a full external
power cycle of the chassis, not just a DPU/ARM reboot. When that happens the
DPU sits in the `Rebooting` phase and its `DPUNode` is annotated
`provisioning.dpu.nvidia.com/dpunode-external-reboot-required=true`.

By default `make install` prints `oc annotate dpunode ...
provisioning.dpu.nvidia.com/dpunode-external-reboot-required-` instructions
at the end instead of waiting. Watch `oc get dpu -A -w`, power-cycle each
bare-metal host when its DPU reaches the `Rebooting` phase, then run the
printed annotation command (or `make external-reboot`) to let provisioning
continue.

Set `ZT_AUTO_POWER_CYCLE=true` to have `make install` do this itself: it
watches for any `DPUNode` requesting an external reboot, power-cycles every
configured chassis over Redfish (the same `WORKER_COUNT`/`BMC_*` used to
power them on initially), waits for the DPU BMCs to answer again, and clears
the annotation, up to `WAIT_EXTERNAL_REBOOT` seconds. This power-cycles real
hardware unattended, so it defaults to off; only enable it once you're
comfortable with that for every configured chassis. `make external-reboot`
runs the same automation by itself at any time, independent of
`ZT_AUTO_POWER_CYCLE`, if you want to trigger it on demand instead of
re-running `make install`.

## Layout

- `manifests/` holds the manifests. Files that contain `${VAR}` are rendered with `envsubst` at apply time.
  `manifests/dpf/zero-trust/` and `manifests/dpu-services/zero-trust/` hold the Zero Trust-only
  manifests; everything else under `manifests/dpf/` and `manifests/dpu-services/` is host-trusted.
- `scripts/` holds one script per phase. Shared helpers, including the Zero Trust helpers, are in `scripts/lib.sh`.
- `generated/` is gitignored. Rendered manifests and other local output go there.

`make render` writes the rendered manifests to `generated/manifests` without applying them.
