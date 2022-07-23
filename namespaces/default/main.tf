resource "kubernetes_namespace" "default_namespace" {
  metadata {
    name = "default"
  }
}

# resource "kubernetes_default_service_account" "default_service_account" {
#   depends_on = [kubernetes_namespace.default_namespace]

#   metadata {
#     namespace = "default"
#   }
#   automount_service_account_token = true
#   image_pull_secret {
#     name = "docker-secret"
#   }
# }


# resource "kubernetes_cluster_role" "default_cluster_role" {
#   metadata {
#     name = "default"
#   }
#   rule {
#     api_groups = ["*"]
#     resources  = ["*"]
#     verbs      = ["*"]
#   }
# }

# resource "kubernetes_cluster_role_binding" "default_cluster_role_binding" {
#   metadata {
#     name = "default"
#   }
#   role_ref {
#     api_group = "rbac.authorization.k8s.io"
#     kind      = "ClusterRole"
#     name      = "default"
#   }
#   subject {
#     kind      = "ServiceAccount"
#     name      = "default"
#     namespace = "default"
#   }
# }
