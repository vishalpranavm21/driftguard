#!/usr/bin/env bash
# The CI/CD pipeline: build -> push -> scan -> CI-sign -> AI score + attest -> commit to Git.
# Flux then deploys from Git, and Kyverno decides whether the pods may run.
# Usage: scripts/build.sh safe | risky
set -euo pipefail
cd "$(dirname "$0")/.."
KIND=${1:-safe}
TAG=$(date +%s)
# Docker only allows plain-HTTP pushes to localhost, so we push through localhost:5000.
# It is the same registry the cluster reaches as k3d-dgreg:5000, and the digest is identical.
IMG=localhost:5000/demo:$KIND-$TAG

echo ">>> [1/6] Build ($KIND)"
docker build -q -f "app/Dockerfile.$KIND" -t "$IMG" app

echo ">>> [2/6] Push"
docker push -q "$IMG" >/dev/null
DIGEST=$(docker inspect --format='{{range .RepoDigests}}{{println .}}{{end}}' "$IMG" | grep '^localhost:5000/demo@' | head -1 | cut -d@ -f2)
REF=k3d-dgreg:5000/demo@$DIGEST
echo "    $REF"

echo ">>> [3/6] Trivy scan"
trivy image -q --format json -o /tmp/trivy.json "$IMG"
jq -r '[.Results[]?.Vulnerabilities[]?.Severity] | group_by(.) | map("\(.[0]): \(length)") | join(", ")' /tmp/trivy.json

echo ">>> [4/6] CI signature"
if ! out=$(COSIGN_PASSWORD="" cosign sign --yes --tlog-upload=false --allow-insecure-registry --allow-http-registry --key ci.key "$REF" 2>&1); then
  echo "$out"; echo "!!! CI signing failed"; exit 1
fi
echo "    signed with ci.key"

echo ">>> [5/6] AI risk score (engine signs the score; it cannot deploy)"
jq -n --arg image "$REF" --slurpfile t /tmp/trivy.json \
      --rawfile d "app/Dockerfile.$KIND" --rawfile m clusters/dev/apps/demo.yaml \
      '{image:$image, trivy:$t[0], dockerfile:$d, manifest:$m}' \
  | curl -sf --max-time 120 -X POST "${ENGINE_URL:-http://localhost:8088}/score/image" -H 'content-type: application/json' -d @- \
  | jq '{risk_score, category, reasons}'

echo ">>> [6/6] GitOps: commit the new image; Flux deploys, Kyverno decides"
sed -i "s#^\(\s*image:\).*#\1 $REF#" clusters/dev/apps/demo.yaml
git add clusters/dev/apps/demo.yaml
git commit -q -m "deploy demo $KIND-$TAG"
git push -q
# A denied Deployment never becomes Ready, so don't wait forever.
flux reconcile kustomization flux-system --with-source --timeout 45s || true
sleep 10
kubectl -n apps get pods -o wide
MSG=$(kubectl -n flux-system get kustomization flux-system -o jsonpath='{.status.conditions[?(@.type=="Ready")].message}')
if echo "$MSG" | grep -q "blocked due to the following policies"; then
  echo "--- DENIED by Kyverno (the pods above keep running the last admitted image) ---"
  echo "$MSG" | grep -E "driftguard-supply-chain|require-" | sed 's/^ */    /'
  exit 3
fi
echo "--- ADMITTED by Kyverno: CI signature valid and AI risk score < 70 ---"
