#!/bin/bash
set -euo pipefail

# create registry container unless it already exists
reg_name='kind-registry'
reg_port='5000'
running="$(docker inspect -f '{{.State.Running}}' "${reg_name}" 2>/dev/null || true)"
if [ "${running}" != 'true' ]; then
  docker run \
    -d --restart=always -p "${reg_port}:5000" --name "${reg_name}" \
    registry:2
fi

# Create 3-node cluster
kind create cluster --config=./cluster.yaml --name redpanda

# connect the registry to the cluster network
# (the network may already be connected)
docker network connect "kind" "${reg_name}" || true

# Document the local registry
# https://github.com/kubernetes/enhancements/tree/master/keps/sig-cluster-lifecycle/generic/1755-communicating-a-local-registry
kubectl apply -f configmap-local-registry-hosting.yaml

# Install vectorized/redpanda:latest to the local repository
echo "Updating local repository with vectorized/redpanda:latest"
docker pull vectorized/redpanda:latest
docker tag vectorized/redpanda:latest localhost:5000/redpanda:latest
docker push localhost:5000/redpanda:latest

NODES=$(kubectl get nodes -o json | jq -r '.items[].status.addresses | select(.[].address | startswith("redpanda-worker")) | .[] | select(.type == "InternalIP").address')
SUBNET=$(echo "$NODES" | head -n1 | cut -d. -f 1,2).255
ADDRESSES="$SUBNET.1-$SUBNET.254"

# Install metallb
helm repo add bitnami https://charts.bitnami.com/bitnami
helm install \
  --create-namespace \
  --namespace metallb-system \
  metallb bitnami/metallb \
  -f metallb-values.yaml \
  --set configInline.address-pools[0].addresses[0]="$ADDRESSES"

# Install redpanda
helm install \
  --create-namespace \
  --namespace redpanda \
  redpanda ../redpanda \
  --set loadBalancer.enabled=true \
  --set image.repository=localhost:5000/redpanda

# Wait for rollout
echo ""
kubectl -n redpanda rollout status -w statefulset/redpanda
echo "
Remove cluster with:

  $ kind delete cluster --name redpanda

Add these to /etc/hosts:
"
kubectl -n redpanda get svc | grep redpanda- | awk '{printf "%-15s %s %s.redpanda.redpanda.svc.cluster.local\n", $4, $1, $1}'
echo "
rpk api status --brokers redpanda-0:9092
"
rpk api status --brokers redpanda-0:9092
