## Istio Multicluster Examples

This is a set of demo/example scripts demonstrating how to setup various forms
of Istio multicluster connectivity and/or enable multicluster for existing Istio
installations.

Prerequisites/requirements:

* Two Kubernetes clusters with admin RBAC credentials granted to the current
  user. Credentials need to be fetched and available in a form of one single or
  two separate `kubeconfig` files. Those steps are cloud provider specific,
  most likely you will want to use default `kubeconfig` file and obtain names
  of cluster contexts for corresponding cluster from the output of
  `kubectl config get-contexts` command.
* The following tools need to be available in the PATH (somewhat varies
  depending on which example you want to use):
  - bash
  - kubectl
  - [helm](https://helm.sh/)
  - curl
  - sed
  - openssl (N/A at the moment -- example certs are currently hardcoded)

Usage:

Make sure prerequisites are met, have the names of corresponding `kubeconfig`
files and/or context names handy, run one or more executable scripts passing
the arguments in a form of environment variables (listed on top of each script).

Example:

```
$ ISTIO_VERTION=1.1.3 \
  KUBECONTEXT1=gke_istio-test-230101_us-central1-a_mc-vpn-c1 \
  KUBECONTEXT2=gke_istio-test-230101_us-central1-a_mc-vpn-c2 \
  ./vpn.sh
```

Available Istio builds (i.e. values for ISTIO_VERSION) can be found here:

* https://gcsweb.istio.io/gcs/istio-release/releases/
* https://gcsweb.istio.io/gcs/istio-prerelease/daily-build/

For more details refer to the corresponding sections of Istio documentation:

* https://istio.io/docs/concepts/multicluster-deployments/
* https://istio.io/docs/setup/kubernetes/install/multicluster/
* https://istio.io/docs/examples/multicluster/

Table of contents:

| Script name       | Description |
| ----------------- | ----------- |
| `vpn.sh`          | Spins up two fresh Istio installations with that are using VPN connectivity mode |
| `gateway.sh`      | Spins up two fresh Istio installations demonstrating how a remote service from another cluster can be called via a multicluster gateway connectivity mode |
| `disconnected.sh` | Sping up two disconnected Istio installation in order to use them with `retrofit.sh` |
| `retrofit.sh`     | Demonstrates how to join two existing disconnected Istio installations into a multicluster mesh using VPN connectivity mode |
