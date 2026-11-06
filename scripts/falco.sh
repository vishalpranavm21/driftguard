#!/usr/bin/env bash
# OPTIONAL (only if you have time, native Ubuntu works best): runtime threat detection.
set -euo pipefail
helm repo add falcosecurity https://falcosecurity.github.io/charts >/dev/null 2>&1 || true
helm repo update >/dev/null
helm upgrade --install falco falcosecurity/falco -n falco --create-namespace \
  --set driver.kind=modern_ebpf --set tty=true --wait --timeout 10m
echo ">>> Simulating an attacker reading /etc/shadow inside the app"
kubectl -n apps exec deploy/demo -- cat /etc/shadow >/dev/null 2>&1 || true
sleep 5
kubectl -n falco logs -l app.kubernetes.io/name=falco --tail=200 | grep -iE "shadow|sensitive" | tail -3
