resource "kubernetes_namespace" "_90dy_namespace" {
  metadata {
    name = "90dy"
  }
}

resource "kubernetes_default_service_account" "_90dy_service_account" {
  depends_on = [kubernetes_namespace._90dy_namespace]

  metadata {
    namespace = "90dy"
  }
  automount_service_account_token = true
  image_pull_secret {
    name = "docker-secret"
  }
}


resource "kubernetes_cluster_role" "_90dy_cluster_role" {
  metadata {
    name = "90dy"
  }
  rule {
    api_groups = ["*"]
    resources  = ["*"]
    verbs      = ["*"]
  }
}

resource "kubernetes_cluster_role_binding" "_90dy_cluster_role_binding" {
  metadata {
    name = "90dy"
  }
  role_ref {
    api_group = "rbac.authorization.k8s.io"
    kind      = "ClusterRole"
    name      = "90dy"
  }
  subject {
    kind      = "ServiceAccount"
    name      = "default"
    namespace = "90dy"
  }
}
