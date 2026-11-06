#!/usr/bin/env bash
# Installs every CLI DriftGuard needs (Ubuntu / WSL2). Safe to re-run.
set -euo pipefail
need() { ! command -v "$1" >/dev/null 2>&1; }

if need docker; then
  curl -fsSL https://get.docker.com | sh
  sudo usermod -aG docker "$USER"
  echo ">>> Docker installed. Log out and back in (or run: newgrp docker), then re-run this script."
  exit 0
fi

if need kubectl; then
  curl -sLO "https://dl.k8s.io/release/$(curl -Ls https://dl.k8s.io/release/stable.txt)/bin/linux/amd64/kubectl"
  sudo install kubectl /usr/local/bin/ && rm kubectl
fi
need helm && curl -s https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash
need k3d  && curl -s https://raw.githubusercontent.com/k3d-io/k3d/main/install.sh | bash
need flux && curl -s https://fluxcd.io/install.sh | sudo bash

if need tofu; then
  curl --proto '=https' --tlsv1.2 -fsSL https://get.opentofu.org/install-opentofu.sh -o /tmp/install-opentofu.sh
  chmod +x /tmp/install-opentofu.sh && /tmp/install-opentofu.sh --install-method deb
fi

if need cosign; then   # pinned to v2: the flags in this project are v2 flags
  curl -sSfL -o /tmp/cosign https://github.com/sigstore/cosign/releases/download/v2.4.1/cosign-linux-amd64
  sudo install /tmp/cosign /usr/local/bin/cosign
fi

need trivy && curl -sfL https://raw.githubusercontent.com/aquasecurity/trivy/main/contrib/install.sh | sudo sh -s -- -b /usr/local/bin

if need conftest; then
  VER=0.56.0
  curl -sL "https://github.com/open-policy-agent/conftest/releases/download/v${VER}/conftest_${VER}_Linux_x86_64.tar.gz" | tar xz -C /tmp conftest
  sudo install /tmp/conftest /usr/local/bin/conftest
fi

sudo apt-get install -y jq python3 python3-venv git >/dev/null

echo "---- versions ----"
docker version --format 'docker {{.Server.Version}}'
kubectl version --client | head -1
helm version --short
k3d version | head -1
tofu version | head -1
flux version --client
cosign version 2>&1 | grep -i gitversion
trivy --version | head -1
conftest --version | head -1
echo "RAM: $(free -h | awk '/Mem:/{print $2}')  CPUs: $(nproc)"
