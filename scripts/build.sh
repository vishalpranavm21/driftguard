#!/usr/bin/env bash
# The CI/CD pipeline: build -> push -> scan -> CI-sign -> AI score + attest -> commit to Git.
# Flux then deploys from Git, and Kyverno decides whether the pods may run.
# Usage: scripts/build.sh safe | risky
set -euo pipefail
cd "$(dirname "$0")/.."
KIND=${1:-safe}
TAG=$(date +%s)
IMG=k3d-dgreg:5000/demo:$KIND-$TAG

echo ">>> [1/6] Build ($KIND)"
docker build -q -f "app/Dockerfile.$KIND" -t "$IMG" app

echo ">>> [2/6] Push"
docker push -q "$IMG" >/dev/null
REF=$(docker inspect --format='{{index .RepoDigests 0}}' "$IMG")
echo "    $REF"

echo ">>> [3/6] Trivy scan"
trivy image -q --format json -o /tmp/trivy.json "$IMG"
jq -r '[.Results[]?.Vulnerabilities[]?.Severity] | group_by(.) | map("\(.[0]): \(length)") | join(", ")' /tmp/trivy.json

echo ">>> [4/6] CI signature"
COSIGN_PASSWORD="" cosign sign --yes --tlog-upload=false --allow-insecure-registry --key ci.key "$REF" 2>/dev/null

echo ">>> [5/6] AI risk score (engine signs the score; it cannot deploy)"
jq -n --arg image "$REF" --slurpfile t /tmp/trivy.json \
      --rawfile d "app/Dockerfile.$KIND" --rawfile m clusters/dev/apps/demo.yaml \
      '{image:$image, trivy:$t[0], dockerfile:$d, manifest:$m}' \
  | curl -sf --max-time 120 -X POST localhost:8080/score/image -H 'content-type: application/json' -d @- \
  | jq '{risk_score, category, reasons}'

echo ">>> [6/6] GitOps: commit the new image; Flux deploys, Kyverno decides"
sed -i "s#^\(\s*image:\).*#\1 $REF#" clusters/dev/apps/demo.yaml
git add clusters/dev/apps/demo.yaml
git commit -q -m "deploy demo $KIND-$TAG"
git push -q
flux reconcile kustomization flux-system --with-source
sleep 15
kubectl -n apps get pods -o wide
echo "--- recent admission events ---"
kubectl -n apps get events --sort-by=.lastTimestamp | grep -iE "kyverno|denied|blocked" | tail -5 || true
