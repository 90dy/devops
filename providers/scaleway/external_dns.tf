
variable "SCW_ACCESS_KEY" { type = string }
variable "SCW_SECRET_KEY" { type = string }
variable "SCW_DEFAULT_ORGANIZATION_ID" { type = string }

resource "kubernetes_service_account" "external_dns" {
  metadata {
    name      = "external-dns"
    namespace = "kube-system"
  }
  automount_service_account_token = true
}

resource "kubernetes_cluster_role" "external_dns" {
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
    namespace = "kube-system"
  }
}

resource "kubernetes_deployment" "external_dns" {
  metadata {
    namespace = "kube-system"
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
        namespace = "kube-system"
        labels = {
          name = "external-dns"
        }
      }
      spec {
        service_account_name            = "external-dns"
        automount_service_account_token = true
        container {
          name  = "external-dns"
          image = "k8s.gcr.io/external-dns/external-dns:v0.12.0"
          args = [
            # "--source=service",
            "--source=ingress",
            "--domain-filter=90dy.me",
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

