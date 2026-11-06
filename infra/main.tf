# Platform settings managed as code. Any manual edit is drift.
terraform {
  required_providers {
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "~> 2.35"
    }
  }
}

provider "kubernetes" {
  config_path    = "~/.kube/config"
  config_context = "k3d-driftguard"
}

resource "kubernetes_namespace_v1" "platform" {
  metadata {
    name = "platform"
  }
}

resource "kubernetes_config_map_v1" "app_config" {
  metadata {
    name      = "app-config"
    namespace = kubernetes_namespace_v1.platform.metadata[0].name
  }
  data = {
    allowed_origins = "https://driftguard.example.com"
    debug_mode      = "false"
  }
}
