#!/usr/bin/env bash
#
# run-lb-netpol-kubetest2-kind.sh
#
# Build Kubernetes, spin up a kind cluster with Calico & MetalLB,
# run only “LB + NetworkPolicy” test, then tear everything down.
#

set -o errexit
set -o nounset
set -o pipefail

# ───────────────────────────────────────────────────────────────────────────────
# 1) Configuration
# ───────────────────────────────────────────────────────────────────────────────

KIND_CLUSTER_NAME="test-cluster"
KIND_NODE_IMAGE="kindest/node:v1.33.1"
KIND_KUBECONFIG="$(pwd)/kind.kubeconfig"

CALICO_MANIFEST="https://docs.projectcalico.org/manifests/calico.yaml" # latestest stable
METALLB_MANIFEST="https://raw.githubusercontent.com/metallb/metallb/v0.15.2/config/manifests/metallb-native.yaml" # latest release can be found at https://github.com/metallb/metallb/releases

METALLB_POOL_CIDR="${METALLB_POOL_CIDR:-172.18.255.1-172.18.255.250}"

POD_CIDR="10.244.0.0/16"

TIMEOUT="3m"

# ───────────────────────────────────────────────────────────────────────────────
# 2) Prerequisites
# ───────────────────────────────────────────────────────────────────────────────

for cmd in kind docker kubectl go kubetest2; do
  if ! command -v "$cmd" &>/dev/null; then
    echo "ERROR: '$cmd' not found in PATH" >&2
    exit 1
  fi
done

echo "Go:      $(go version)"
echo "Kind:    $(kind --version)"
echo "Docker:  $(docker version --format '{{.Server.Version}}')"
echo "kubectl: $(kubectl version --client)"

# ───────────────────────────────────────────────────────────────────────────────
# 3) Build Kubernetes + e2e.test
# ───────────────────────────────────────────────────────────────────────────────

echo
echo ">>> Building quick-release artifacts..."
sudo setenforce 0
make all
sudo setenforce 1

RUN_BIN_DIR="$(pwd)/_output/bin"
echo ">>> Local test binaries live in ${RUN_BIN_DIR}"

# ───────────────────────────────────────────────────────────────────────────────
# 4) Clean up old kind
# ───────────────────────────────────────────────────────────────────────────────

echo
echo ">>> Deleting existing kind cluster (if any)…"
if kind get clusters | grep -q "^${KIND_CLUSTER_NAME}$"; then
  kind delete cluster --name "${KIND_CLUSTER_NAME}"
fi

# ───────────────────────────────────────────────────────────────────────────────
# 5) Write a simple kind config
# ───────────────────────────────────────────────────────────────────────────────

cat <<EOF > hack/kind-config.yaml
kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4
networking:
  disableDefaultCNI: true
kubeadmConfigPatches:
- |
  kind: KubeProxyConfiguration
  apiVersion: kubeproxy.config.k8s.io/v1alpha1
  mode: "iptables"
  # make sure this matches your Pod CIDR (Calico default)
  clusterCIDR: "${POD_CIDR}"
nodes:
- role: control-plane
- role: worker
EOF

# ───────────────────────────────────────────────────────────────────────────────
# 6) Create kind + install Calico & MetalLB
# ───────────────────────────────────────────────────────────────────────────────

echo
echo ">>> Creating kind cluster…"
kind create cluster \
  --name "${KIND_CLUSTER_NAME}" \
  --image "${KIND_NODE_IMAGE}" \
  --config hack/kind-config.yaml \
  --kubeconfig "${KIND_KUBECONFIG}"
export KUBECONFIG="${KIND_KUBECONFIG}"

echo
echo ">>> Installing Calico…"
kubectl apply -f "${CALICO_MANIFEST}"
kubectl -n kube-system rollout status ds/calico-node --timeout="${TIMEOUT}"
kubectl -n kube-system rollout status deployment/calico-kube-controllers --timeout="${TIMEOUT}"

echo
echo ">>> Installing MetalLB…"
kubectl apply -f "${METALLB_MANIFEST}"
kubectl -n metallb-system rollout status deployment/controller --timeout="${TIMEOUT}"
kubectl -n metallb-system rollout status daemonset/speaker --timeout="${TIMEOUT}"

cat <<EOF | kubectl apply -f -
apiVersion: metallb.io/v1beta1
kind: IPAddressPool
metadata:
  namespace: metallb-system
  name: kind-pool
spec:
  addresses:
  - ${METALLB_POOL_CIDR}
---
apiVersion: metallb.io/v1beta1
kind: L2Advertisement
metadata:
  namespace: metallb-system
  name: kind-l2
spec:
  ipAddressPools:
  - kind-pool
EOF

echo "  • MetalLB pool: ${METALLB_POOL_CIDR}"

# Compute the VIP from the pool
LB_VIP="${METALLB_POOL_CIDR%-*}"
echo "  • LoadBalancer VIP will be: ${LB_VIP}"

# ───────────────────────────────────────────────────────────────────────────────
# 7) Run just our LoadBalancer+NetPol test via kubetest2-kind
    # --focus-regex='\[Feature:NetworkPolicy\]' \             
# ───────────────────────────────────────────────────────────────────────────────

echo
echo ">>> Running LB+NetworkPolicy e2e test with kubetest2-kind…"

# make sure we pick up your locally-built binaries
export KUBE_ROOT=$(pwd)
export PATH=$KUBE_ROOT/_output/bin:$PATH

kubetest2 kind  \
  --cluster-name "${KIND_CLUSTER_NAME}" \
  --config hack/kind-config.yaml \
  --image-name "${KIND_NODE_IMAGE}" \
  --test=ginkgo \
  -- \
    --use-binaries-from-path \
    --focus-regex='should enforce default-deny ingress policy against LoadBalancer traffic with ExternalTrafficPolicy:' \
    --skip-regex='\[Serial\]' \
    --ginkgo-args='--v' \
    --test-args="--kubeconfig=${KIND_KUBECONFIG}" \


EXIT_CODE=$?

# ───────────────────────────────────────────────────────────────────────────────
# 8) Tear down
# ───────────────────────────────────────────────────────────────────────────────

echo
echo ">>> Deleting kind cluster…"
kind delete cluster --name "${KIND_CLUSTER_NAME}"

echo
echo ">>> All done (exit code ${EXIT_CODE})"
exit ${EXIT_CODE}