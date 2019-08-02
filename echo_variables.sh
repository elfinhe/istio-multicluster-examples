
#!/bin/bash -e
set -x
### script arguments
# ISTIO_VERSION: e.g. "1.1.3" or "release-1.1-20190417-09-16"
ISTIO_VERSION="${ISTIO_VERSION:-release-1.1-latest-daily}"
# KUBECONFIG: path to a kubeconfig file
KUBECONFIG1="${KUBECONFIG1:-${HOME}/.kube/config}"
KUBECONFIG2="${KUBECONFIG2:-${HOME}/.kube/config}"
# KUBECONTEXT: empty value defaults to "current" context of given kubeconfig file
KUBECONTEXT1="${KUBECONTEXT1:-$(kubectl --kubeconfig=${KUBECONFIG1} config current-context)}"
KUBECONTEXT2="${KUBECONTEXT2:-$(kubectl --kubeconfig=${KUBECONFIG2} config current-context)}"
###


