#!/usr/bin/env bash
# OPTIONAL (only if you have time, native Ubuntu works best): runtime threat detection.
set -euo pipefail
helm repo add falcosecurity https://falcosecurity.github.io/charts >/dev/null 2>&1 || true
helm repo update >/dev/null
helm upgrade --install falco falcosecurity/falco -n falco --create-namespace \
  --set driver.kind=modern_ebpf --set tty=true --wait --timeout 10m
kubectl -n falco rollout status ds/falco --timeout 5m
sleep 10   # let the eBPF probe and rules load
echo ">>> Simulating an attacker inside the app: reading /etc/shadow and hunting for private keys"
# The app runs as non-root, so the shadow read is refused (good). The key search still runs and Falco flags it.
kubectl -n apps exec deploy/demo -- sh -c 'cat /etc/shadow; find / -name id_rsa' >/dev/null 2>&1 || true
sleep 5
kubectl -n falco logs -l app.kubernetes.io/name=falco -c falco --tail=500 \
  | grep -iE "shadow|sensitive|private keys" | grep "container_name=demo" | tail -3
