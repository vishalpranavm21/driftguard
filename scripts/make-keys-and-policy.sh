#!/usr/bin/env bash
# Creates the two signing identities and renders the Kyverno policy with their public keys.
#   ci.key  -> "this image was built by our pipeline"
#   ai.key  -> "this is the AI risk score"   (only the AI engine uses it)
set -euo pipefail
cd "$(dirname "$0")/.."

[ -f ci.key ] || COSIGN_PASSWORD="" cosign generate-key-pair --output-key-prefix ci
[ -f ai.key ] || COSIGN_PASSWORD="" cosign generate-key-pair --output-key-prefix ai

python3 - <<'EOF'
import pathlib
tmpl = pathlib.Path("policies/kyverno/supply-chain.tmpl.yaml").read_text()
out = []
for line in tmpl.splitlines():
    for marker, keyfile in (("__CI_PUB__", "ci.pub"), ("__AI_PUB__", "ai.pub")):
        if marker in line:
            indent = line[: len(line) - len(line.lstrip())]
            key = pathlib.Path(keyfile).read_text().strip().splitlines()
            line = "\n".join(indent + k for k in key)
    out.append(line)
dest = pathlib.Path("clusters/dev/apps/supply-chain.yaml")
dest.write_text("\n".join(out) + "\n")
print(f"wrote {dest}")
EOF
