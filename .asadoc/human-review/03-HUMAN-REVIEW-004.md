# HUMAN-REVIEW-004: ignore files

- **Priority:** 3
- **Status:** ignored
- **TODO:** none in the repo: ignored blocks have no code counterpart

`.asadoc/ignore/example-output`, `manual-command` and `no-repo-source` started as a copy of openshift-dpf's. Both repos check the same docs at the same ref, so the blocks are the same. Some reasons were decided for openshift-dpf's code, though. For example, the CSR approval command (openshift-dpf HUMAN-REVIEW-021) is close to `approve_pending_csrs` here, but not identical: the installer checks for pending CSRs first and passes `xargs -r`.

Blocks ignored for the installer:

- `prerequisite/`: the MCE Subscription and MultiClusterEngine. The README lists MCE with Hypershift as a prerequisite, and `make preflight` checks for it.
- `no-repo-source/traffic-test-pods.txt`: the installer has no traffic test workload.
- `no-repo-source/baremetalhost-without-dpu.txt`: the installer only provisions DPU workers. Workers without a DPU are a Technology Preview in the docs.

The docs' environment variable exports (`nw-dpf-environment-variables`, `nw-dpf-hcp-environment-variables`) stay ignored. Their values differ from `.env.example` (for example, `NODES_MTU` 1500 in the docs vs 9000 here).

**Decide:** whether the copied reasons hold for the installer.
