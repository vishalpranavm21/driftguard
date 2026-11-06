# DriftGuard: AI-Guardrailed GitOps Platform (open-source edition)

A self-healing GitOps platform where **Claude scores every change** and **policy engines decide**.
The AI can sign a risk score, but it has no rights to deploy anything.

| Capability | How |
| --- | --- |
| Kubernetes drift self-healing | FluxCD re-applies Git and reverts manual `kubectl` changes |
| Infrastructure drift detection | `tofu plan -detailed-exitcode`, then AI score, then OPA gate, then apply |
| AI risk scoring | FastAPI + Claude API (forced tool output, fail-closed) |
| Admission control | Kyverno verifies the CI signature and the AI-signed risk attestation (< 70) |
| Supply chain | Trivy scan + cosign signatures/in-toto attestations |
| Runtime detection (optional) | Falco |

## Architecture

```
git push -> scripts/build.sh: build -> push -> Trivy -> cosign sign (CI key)
                                   -> AI engine: Claude score -> cosign attest (AI key)
                                   -> commit image digest to Git
Flux pulls Git -> Kubernetes API -> Kyverno: CI signature valid AND risk_score < 70 ? admit : deny

kubectl edit (drift) -> scripts/plan.sh: tofu plan -> AI score -> conftest (OPA) -> tofu apply | BLOCKED
```

## Design decisions
1. **The AI has no execution authority.** The engine never calls the Kubernetes API or writes to Git.
2. **The AI can only tighten.** Fixed OPA and Kyverno rules always run as well.
3. **It fails closed.** If the engine or Claude errors, the score is 100 and the change is blocked.
4. **Secrets stay local.** Sensitive plan values are masked before the API call.
5. **Change content is untrusted data**, so prompt injection inside a change can't loosen a policy.

## Quick start
```bash
scripts/install-tools.sh
scripts/setup-cluster.sh
flux bootstrap github --owner=$GITHUB_USER --repository=driftguard --personal --path=clusters/dev
scripts/make-keys-and-policy.sh
(cd engine && python3 -m venv .venv && . .venv/bin/activate && pip install -r requirements.txt && uvicorn app:app --port 8080)
scripts/build.sh safe     # admitted
scripts/build.sh risky    # denied by Kyverno with Claude's reasons
scripts/plan.sh           # infrastructure drift -> AI -> OPA -> heal
```

## Roadmap (production version)
Gitea, Harbor, Jenkins (pods log in to OpenBao with their ServiceAccount tokens: no static secrets),
Atlantis PR workflow, OpenBao Transit-held signing keys, the engine running inside the cluster with zero RBAC,
HA cluster with TLS everywhere.
