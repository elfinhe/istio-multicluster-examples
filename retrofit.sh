#!/bin/bash -e

### script arguments
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

function install_slave_cluster_secrets {
  local KUBECONFIG_MASTER="${1:?required argument is not set or empty}"
  local KUBECONTEXT_MASTER="${2:?required argument is not set or empty}"
  local KUBECONFIG_SLAVE="${3:?required argument is not set or empty}"
  local KUBECONTEXT_SLAVE="${4:?required argument is not set or empty}"

  local KUBECTL_MASTER="kubectl --kubeconfig=${KUBECONFIG_MASTER} --context=${KUBECONTEXT_MASTER}"
  local KUBECTL_SLAVE="kubectl --kubeconfig=${KUBECONFIG_SLAVE} --context=${KUBECONTEXT_SLAVE}"

  local CLUSTER_NAME=$($KUBECTL_SLAVE config view -o jsonpath="{.contexts[?(@.name == \"${KUBECONTEXT_SLAVE}\")].context.cluster}")
  local SERVER=$($KUBECTL_SLAVE config view -o jsonpath="{.clusters[?(@.name == \"${CLUSTER_NAME}\")].cluster.server}")
  local NAMESPACE=istio-system
  local SERVICE_ACCOUNT=istio-pilot-service-account
  local SECRET_NAME=$($KUBECTL_SLAVE get sa ${SERVICE_ACCOUNT} -n ${NAMESPACE} -o jsonpath="{.secrets[].name}")
  local CA_DATA=$($KUBECTL_SLAVE get secret ${SECRET_NAME} -n ${NAMESPACE} -o jsonpath="{.data['ca\.crt']}")
  local TOKEN=$($KUBECTL_SLAVE get secret ${SECRET_NAME} -n ${NAMESPACE} -o jsonpath="{.data['token']}" | base64 --decode)

  local TEMP_DIR=$(mktemp -d)
  local KUBECFG_FILE=$TEMP_DIR/kubeconfig

  cat > $KUBECFG_FILE <<EOF
apiVersion: v1
kind: Config
clusters:
- cluster:
    certificate-authority-data: ${CA_DATA}
    server: ${SERVER}
  name: ${CLUSTER_NAME}
contexts:
- context:
    cluster: ${CLUSTER_NAME}
    user: ${CLUSTER_NAME}
  name: ${CLUSTER_NAME}
current-context: ${CLUSTER_NAME}

preferences: {}
users:
- name: ${CLUSTER_NAME}
  user:
    token: ${TOKEN}
EOF

  local SECRET_NAME=$(cat /dev/urandom | env LC_CTYPE=C tr -dc 'a-z0-9' | fold -w 32 | head -n 1)

  $KUBECTL_MASTER create secret generic ${SECRET_NAME} --from-file ${KUBECFG_FILE} -n ${NAMESPACE}
  $KUBECTL_MASTER label secret ${SECRET_NAME} istio/multiCluster=true -n ${NAMESPACE}

  rm -rf $TEMP_DIR

  sleep 5
}

function copy_istio_secrets {
  local KUBECTL_SRC="${1:?required argument is not set or empty}"
  local KUBECTL_DST="${2:?required argument is not set or empty}"

  $KUBECTL_DST -n istio-system scale deployment istio-citadel --replicas=0
  $KUBECTL_DST -n istio-system rollout status deployment istio-citadel

  $KUBECTL_DST -n istio-system delete secret istio-ca-secret || true
  $KUBECTL_DST -n istio-system delete secret cacerts || true

  for ns in `$KUBECTL_DST get ns -o=jsonpath="{.items[*].metadata.name}"`; do
    echo $ns
    $KUBECTL_DST -n $ns delete secret istio.default || true
  done

  PLUGGED_SECRET=$($KUBECTL_SRC -n istio-system get secret cacerts -o yaml --export || true)
  if [[ -n "$PLUGGED_SECRET" ]]; then
    echo "$PLUGGED_SECRET" | $KUBECTL_DST -n istio-system apply --validate=false -f -
  fi

  SELFSIGNED_SECRET=$($KUBECTL_SRC -n istio-system get secret istio-ca-secret -o yaml --export || true)
  if [[ -n "$SELFSIGNED_SECRET" ]]; then
    echo "$SELFSIGNED_SECRET" | $KUBECTL_DST -n istio-system apply --validate=false -f -
  fi

  $KUBECTL_DST -n istio-system scale deployment istio-citadel --replicas=1
  $KUBECTL_DST -n istio-system rollout status deployment istio-citadel

  sleep 5
}

function rekick_deployments {
  local KUBECTL="${1:?required argument is not set or empty}"

  for ns in `$KUBECTL get ns -o=jsonpath="{.items[*].metadata.name}"`; do
    if [[ ! $ns =~ ^namespace/kube- ]]; then
      for depl in `$KUBECTL -n $ns get deployment -o=name`; do
        $KUBECTL -n $ns patch $depl -p "{\"spec\":{\"template\":{\"metadata\":{\"annotations\":{\"date\":\"`date +'%s'`\"}}}}}"
      done
    fi
  done

  for ns in `$KUBECTL get ns -o=jsonpath="{.items[*].metadata.name}"`; do
    if [[ ! $ns =~ ^namespace/kube- ]]; then
      for depl in `$KUBECTL -n $ns get deployment -o=name`; do
        $KUBECTL -n $ns rollout status $depl || true
      done
    fi
  done

  sleep 5
}

function check_probe_multicluster {
  local KUBECTL="${1:?required argument is not set or empty}"

  local POD=$($KUBECTL -n test get pod -l app=test-srv -o jsonpath="{.items[0].metadata.name}")
  local SVCADDR1=$($KUBECTL -n test exec -it $POD -c fortio-server -- \
    fortio curl http://test-srv.test.svc.cluster.local:8080/debug?env=dump \
    | grep "^TEST_SRV_SERVICE_HOST=")
  echo "received response from: $SVCADDR1"

  for i in {1..10}; do
    local SVCADDR2=$($KUBECTL -n test exec -it $POD -c fortio-server -- \
      fortio curl http://test-srv.test.svc.cluster.local:8080/debug?env=dump \
      | grep "^TEST_SRV_SERVICE_HOST=")
    if [[ $SVCADDR1 != $SVCADDR2 ]]; then
      echo "received response from: $SVCADDR2"
      return 0
    fi
  done

  echo "never received response from any other host"
  return 1
}

### main block

TEMP_DIR=$(mktemp -d)

KUBECTL1="kubectl --kubeconfig=${KUBECONFIG1} --context=${KUBECONTEXT1}"
KUBECTL2="kubectl --kubeconfig=${KUBECONFIG2} --context=${KUBECONTEXT2}"

echo -e "\n [*] replacing Istio secrets in the second cluster with secrets from the first cluster ... \n"
copy_istio_secrets "$KUBECTL1" "$KUBECTL2"
echo -e "\n [OK] replaced Istio secrets \n"

echo -e "\n [*] rekicking all deployments ... \n"
rekick_deployments "$KUBECTL2"
echo -e "\n [OK] rekicked all deployments \n"

echo -e "\n [*] installing probe apps ... \n"
install_probe "$KUBECTL1"
install_probe "$KUBECTL2"
echo -e "\n [OK] installed probe apps \n"

echo -e "\n [*] verifying that probe apps are reachable ... \n"
check_probe "$KUBECTL1"
check_probe "$KUBECTL2"
echo -e "\n [OK] successfully verified that probe apps are reachable \n"

echo -e "\n [*] installing K8S API secrets of the remote clusters ... \n"
install_slave_cluster_secrets "$KUBECONFIG1" "$KUBECONTEXT1" "$KUBECONFIG2" "$KUBECONTEXT2"
install_slave_cluster_secrets "$KUBECONFIG2" "$KUBECONTEXT2" "$KUBECONFIG1" "$KUBECONTEXT1"
echo -e "\n [*] installed K8S API secrets of the remote clusters \n"

echo -e "\n [*] verifying that probe requests are load-balanced between both clusters... \n"
check_probe_multicluster "$KUBECTL1"
check_probe_multicluster "$KUBECTL2"
echo -e "\n [OK] verified that probe requests are load-balanced between both clusters \n"

echo -e "\n [OK] ALL DONE! \n"
rm -rf $TEMP_DIR
