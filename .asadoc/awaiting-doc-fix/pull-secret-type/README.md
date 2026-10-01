The docs create the hosted cluster pull secret with `--type=Opaque`. It holds a `.dockerconfigjson` key, so the installer uses `--type=kubernetes.io/dockerconfigjson`, like the DPF HCP provisioner does for the copy it makes for the HostedCluster.

Docs fix: https://github.com/openshift/openshift-docs/pull/121145
