# HUMAN-REVIEW-003: code changed to match the docs

- **Priority:** 5
- **Status:** matched (code changed)
- **TODO:** `# TODO` comments on `helm_upgrade` and `apply_secret` in `scripts/lib.sh`

These code changes make the installer match the docs:

- `helm_upgrade` now adds `--timeout "$HELM_TIMEOUT"` itself, instead of each call passing it. All calls used the same timeout.
- For the charts whose docs leave out `--wait` (dpu-worker-config, dpf-hcp-provisioner, the OVN-Kubernetes injector, grafana-operator), `--wait` moved from the last line to the middle, so a single `remove-lines-starting-with` drops it. The flags passed are the same.
- `apply_secret` no longer takes the namespace as its first argument. Callers pass `-n` at the end, as `oc create secret` does.
- The SSH key secret now passes `--type=Opaque`, the default for `generic` secrets anyway.
- The maintenance-operator values path goes through a `values_file` variable, so the `--values` argument is a single param.
- The IP forwarding patch uses `-p` instead of `--patch`.
- `dpfoperatorconfig.yaml` has the docs' inline comments on the MTU and OOB bridge lines.
- `"$OVN_CHART_VERSION"` became `"${OVN_CHART_VERSION}"` in `injector.sh`, so `${*}` covers it.

`make check` passes. Rendered manifests differ from before only in comments. With `oc` and `helm` stubbed, the platform, cluster-prep, dpf, hosted, injector and observability phases make the same calls as before, except flag order, `-p` and the SSH secret's `--type=Opaque`. Nothing was tested on a cluster.

**Decide:** whether these changes are acceptable.
