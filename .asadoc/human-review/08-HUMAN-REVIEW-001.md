# HUMAN-REVIEW-001: `openshift-docs:nw-dpf-creating-dpuflavor/yaml-001`

- **Priority:** 8
- **Status:** unresolved (closest: `manifests/dpu-services/dpuflavor.yaml`, the code has 3 lines more)
- **TODO:** TODO on the marker in `manifests/dpu-services/dpuflavor.yaml`

The docs have two DPUFlavors: one for standard MTU (1500) and one for jumbo frames (9000). The installer only ships the jumbo one, which matches `yaml-002`. It sets `mtu_request=9000` on `br-dpu` and `br-ovn` and adds `NUM_VF_MSIX=30`, whatever `NODES_MTU` is.

`NODES_MTU` can still be set in `.env`, and the docs default it to 1500. With `NODES_MTU=1500` the installer would set a 1500 MTU in `DPFOperatorConfig` but configure 9000 MTU bridges on the DPU.

**Decide:** add the 1500 flavor and pick it from `NODES_MTU`, or require `NODES_MTU=9000` (for example in `make preflight`) and ignore this block.
