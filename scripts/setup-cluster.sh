#!/usr/bin/env bash
# Creates the local registry + k3d cluster and installs Kyverno. Safe to re-run.
set -euo pipefail
CLUSTER=driftguard
REG=dgreg               # registry container will be called k3d-dgreg, port 5000

grep -q "k3d-$REG" /etc/hosts || echo "127.0.0.1 k3d-$REG" | sudo tee -a /etc/hosts

k3d registry list 2>/dev/null | grep -q "k3d-$REG" || k3d registry create "$REG" --port 5000
k3d cluster list 2>/dev/null | grep -q "^$CLUSTER " || \
  k3d cluster create "$CLUSTER" --agents 1 --registry-use "k3d-$REG:5000" --wait
kubectl config use-context "k3d-$CLUSTER"
kubectl get nodes

echo ">>> Installing Kyverno (takes 2-4 minutes)"
helm repo add kyverno https://kyverno.github.io/kyverno/ >/dev/null 2>&1 || true
helm repo update >/dev/null
helm upgrade --install kyverno kyverno/kyverno -n kyverno --create-namespace \
  --set features.registryClient.allowInsecure=true \
  --wait --timeout 10m
kubectl -n kyverno get pods

echo ">>> Checking that pods can resolve the registry (Kyverno needs this)"
# busybox nslookup exits non-zero on search-domain NXDOMAINs, so test the registry API instead
kubectl delete pod dnstest --ignore-not-found >/dev/null 2>&1
kubectl run dnstest --rm -i --restart=Never --image=busybox:1.36 -- wget -qO- "http://k3d-$REG:5000/v2/_catalog" \
  && echo "DNS OK" || echo "!!! DNS check failed - send this output to Claude"
