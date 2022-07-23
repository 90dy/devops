// https://registry.terraform.io/providers/scaleway/scaleway/latest/docs/resources/k8s_cluster_beta#expander

variable "SCW_ACCESS_KEY" { type = string }
variable "SCW_SECRET_KEY" { type = string }
variable "SCW_DEFAULT_ORGANIZATION_ID" { type = string }

variable "KUBE_CONFIG_PATH" { type = string }

terraform {
  backend "kubernetes" {
    secret_suffix    = "state"
    load_config_file = true
  }
}

provider "kubernetes" {
  config_path = var.KUBE_CONFIG_PATH
}

// https://github.com/kubernetes-sigs/external-dns/blob/master/docs/tutorials/scaleway.md
// https://particule.io/blog/scaleway-externaldns/
resource "kubernetes_deployment" "external_dns" {
  count      = var.PROVIDER == "scaleway" ? 1 : 0
  depends_on = [kubernetes_namespace.default_namespace]

  metadata {
    namespace = "default"
    name      = "external-dns"
  }

  timeouts {
    create = "30s"
  }

  spec {
    selector {
      match_labels = {
        name = "external-dns"
      }
    }
    strategy {
      type = "Recreate"
    }
    template {
      metadata {
        namespace = "default"
        labels = {
          name = "external-dns"
        }
      }
      spec {
        service_account_name            = "external-dns"
        automount_service_account_token = true
        container {
          name  = "external-dns"
          image = "k8s.gcr.io/external-dns/external-dns:v0.7.4"
          args = [
            "--source=service",
            "--domain-filter=kube.default.me",
            "--provider=scaleway",
            "--namespace=default"
          ]
          env {
            name  = "SCW_ACCESS_KEY"
            value = var.SCW_ACCESS_KEY
          }
          env {
            name  = "SCW_SECRET_KEY"
            value = var.SCW_SECRET_KEY
          }
          env {
            name  = "SCW_DEFAULT_ORGANIZATION_ID"
            value = var.SCW_DEFAULT_ORGANIZATION_ID
          }
        }
      }
    }
  }
}

// create service account external-dns
resource "kubernetes_service_account" "external_dns" {
  count      = var.PROVIDER == "scaleway" ? 1 : 0
  depends_on = [kubernetes_namespace.default_namespace]

  metadata {
    name      = "external-dns"
    namespace = "default"
  }
  automount_service_account_token = true
}

// create cluster role external-dns
resource "kubernetes_cluster_role" "external_dns" {
  count = var.PROVIDER == "scaleway" ? 1 : 0
  metadata {
    name = "external-dns"
  }

  rule {
    api_groups = [""]
    resources  = ["services", "endpoints", "pods"]
    verbs      = ["get", "watch", "list"]
  }
  rule {
    api_groups = ["networking.k8s.io"]
    resources  = ["ingresses"]
    verbs      = ["get", "watch", "list"]
  }
  rule {
    api_groups = [""]
    resources  = ["nodes"]
    verbs      = ["list", "watch"]
  }
}

// bind cluster role external-dns to service account external-dns
resource "kubernetes_cluster_role_binding" "external_dns" {
  count      = var.PROVIDER == "scaleway" ? 1 : 0
  depends_on = [kubernetes_namespace.default_namespace]

  metadata {
    name = "external-dns"
  }
  role_ref {
    api_group = "rbac.authorization.k8s.io"
    kind      = "ClusterRole"
    name      = "external-dns"
  }
  subject {
    kind      = "ServiceAccount"
    name      = "external-dns"
    namespace = "default"
  }
}

