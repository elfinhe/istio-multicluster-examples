#!/bin/bash -e

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

### script arguments sanity checks
if [[ $KUBECONFIG1 == $KUBECONFIG2 ]] && [[ $KUBECONTEXT1 == $KUBECONTEXT2 ]]; then
  echo
  echo " [FAIL] KUBECONFIG{1,2}/KUBECONTEXT{1,2} pairs refer to the same cluster"
  echo "        this configuration requires two distinct clusters, terminating..."
  echo
  exit 1
fi
###

function download_istio_dist {
  local ISTIO_VERSION="${1:?required argument is not set or empty}"
  local ISTIO_DIST_DIR="${2:?required argument is not set or empty}"

  mkdir -p $ISTIO_DIST_DIR

  local BUCKET_CONTENTS
  local BUCKET_URL

  # looking for a RELEASE
  local RELEASE_BUCKET_URL="https://storage.googleapis.com/istio-release/?prefix=releases/${ISTIO_VERSION}/"
  if [[ -z "$BUCKET_URL" ]]; then
    BUCKET_CONTENTS=$(curl --location --fail $RELEASE_BUCKET_URL)
    if [[ $BUCKET_CONTENTS == *"charts/index.yaml"* ]]; then
      BUCKET_URL=$(echo $RELEASE_BUCKET_URL | sed 's/?.*//')
    fi
  fi

  # looking for a DAILY BUILD
  local SNAPSHOT_BUCKET_URL="https://storage.googleapis.com/istio-prerelease/?prefix=daily-build/${ISTIO_VERSION}/"
  if [[ -z "$BUCKET_URL" ]]; then
    BUCKET_CONTENTS=$(curl --location --fail $SNAPSHOT_BUCKET_URL)
    if [[ $BUCKET_CONTENTS == *"charts/index.yaml"* ]]; then
      BUCKET_URL=$(echo $SNAPSHOT_BUCKET_URL | sed 's/?.*//')
    fi
  fi

  if [[ -z "$BUCKET_URL" ]]; then
    echo "couldn't find specified Istio release"
    return 1
  fi

  echo $BUCKET_URL

  # distribution found, downloading artifacts
  local ISTIO_URL=$(sed -ne '/.*/{s/.*<Key>\([^<>]*charts\/istio-[0-9][^<>]*\.tgz\)<\/Key>.*/\1/p;q;}' <<< "$BUCKET_CONTENTS")
  local ISTIO_INIT_URL=$(sed -ne '/.*/{s/.*<Key>\([^<>]*charts\/istio-init-[^<>]*\.tgz\)<\/Key>.*/\1/p;q;}' <<< "$BUCKET_CONTENTS")

  : "${ISTIO_URL:?failed to locate istio-<RELEASE>.tgz}"
  : "${ISTIO_INIT_URL:?failed to locate istio-init-<RELEASE>.tgz}"

  curl --location --fail "${BUCKET_URL}${ISTIO_URL}" -o "${ISTIO_DIST_DIR}/istio.tgz"
  curl --location --fail "${BUCKET_URL}${ISTIO_INIT_URL}" -o "${ISTIO_DIST_DIR}/istio-init.tgz"

  tar xzf "${ISTIO_DIST_DIR}/istio.tgz" -C "${ISTIO_DIST_DIR}"
  tar xzf "${ISTIO_DIST_DIR}/istio-init.tgz" -C "${ISTIO_DIST_DIR}"
}

function ensure_namespace_exists {
  local KUBECTL="${1:?required argument is not set or empty}"
  $KUBECTL create namespace "istio-system" || true
}

function install_istio_init {
  local KUBECTL="${1:?required argument is not set or empty}"
  local ISTIO_INIT_DIR="${2:?required argument is not set or empty}"

  helm template $ISTIO_INIT_DIR --name istio-init --namespace istio-system | $KUBECTL apply -f -

  until [[ "$($KUBECTL get crds | grep 'istio.io\|certmanager.k8s.io' | wc -l)" -gt 52 ]]; do
    echo "awaiting CRDs creation..."
    sleep 3
  done
}

function install_istio {
  local KUBECTL="${1:?required argument is not set or empty}"
  local ISTIO_DIR="${2:?required argument is not set or empty}"

  helm template $ISTIO_DIR --name istio \
    --namespace istio-system \
    --set global.controlPlaneSecurityEnabled=false \
    --set global.mtls.enabled=true \
    --set security.selfSigned=true \
    | $KUBECTL apply -f -
}

function await_istio_rollout {
  local KUBECTL="${1:?required argument is not set or empty}"

  $KUBECTL -n istio-system rollout status deployment istio-ingressgateway
}

function install_probe {
  local KUBECTL="${1:?required argument is not set or empty}"

  $KUBECTL create ns test || true
  $KUBECTL label --overwrite=true ns test istio-injection=enabled || true
  $KUBECTL apply -f - <<EOF
apiVersion: v1
kind: Service
metadata:
  name: test-srv
  namespace: test
spec:
  ports:
  - port: 8080
    name: http-echo
  selector:
    app: test-srv
---
apiVersion: apps/v1beta1
kind: Deployment
metadata:
  name: test-srv
  namespace: test
spec:
  template:
    metadata:
      labels:
        app: test-srv
    spec:
      containers:
      - name: fortio-server
        image: fortio/fortio
        ports:
        - containerPort: 8080
        args:
        - server
EOF

  $KUBECTL -n test rollout status deployment test-srv

  sleep 5
}

function check_probe {
  local KUBECTL="${1:?required argument is not set or empty}"

  local POD=$($KUBECTL -n test get pod -l app=test-srv -o jsonpath="{.items[0].metadata.name}")
  $KUBECTL -n test exec -it $POD -c fortio-server -- fortio curl http://test-srv.test.svc.cluster.local:8080/debug?env=dump
}

### main block

TEMP_DIR=$(mktemp -d)
ISTIO_DIST_DIR="${TEMP_DIR}/istio"

KUBECTL1="kubectl --kubeconfig=${KUBECONFIG1} --context=${KUBECONTEXT1}"
KUBECTL2="kubectl --kubeconfig=${KUBECONFIG2} --context=${KUBECONTEXT2}"

echo -e "\n [*] downloading Istio (version: ${ISTIO_VERSION}) to $ISTIO_DIST_DIR ... \n"
download_istio_dist "$ISTIO_VERSION" "$ISTIO_DIST_DIR"
echo -e "\n [OK] downloaded Istio (version: ${ISTIO_VERSION}) to $ISTIO_DIST_DIR \n"

echo -e "\n [*] ensuring Istio namespaces exist ... \n"
ensure_namespace_exists "$KUBECTL1"
ensure_namespace_exists "$KUBECTL2"
echo -e "\n [OK] ensured Istio namespaces exist \n"

echo -e "\n [*] installing Istio Init (CRDs) ... \n"
install_istio_init "$KUBECTL1" "${ISTIO_DIST_DIR}/istio-init"
install_istio_init "$KUBECTL2" "${ISTIO_DIST_DIR}/istio-init"
echo -e "\n [OK] installed Istio Init (CRDs) \n"

echo -e "\n [*] installing Istio ... \n"
install_istio "$KUBECTL1" "${ISTIO_DIST_DIR}/istio"
install_istio "$KUBECTL2" "${ISTIO_DIST_DIR}/istio"
echo -e "\n [OK] installed Istio \n"

echo -e "\n [*] waiting till everything's running ... \n"
await_istio_rollout "$KUBECTL1"
await_istio_rollout "$KUBECTL2"
echo -e "\n [OK] looks like everything's running \n"

echo -e "\n [*] installing probe apps ... \n"
install_probe "$KUBECTL1"
install_probe "$KUBECTL2"
echo -e "\n [OK] installed probe apps \n"

echo -e "\n [*] verifying that probe apps are reachable ... \n"
check_probe "$KUBECTL1"
check_probe "$KUBECTL2"
echo -e "\n [OK] successfully verified that probe apps are reachable \n"


echo -e "\n [OK] ALL DONE! \n"
