
resource "kubernetes_service_account" "diun" {
  depends_on = [kubernetes_namespace.default, kubernetes_secret.default_docker_config]
  metadata {
    namespace = "default"
    name      = "diun"
  }
  automount_service_account_token = true
  timeouts {
    create = "2m"
  }
  image_pull_secret {
    name = "docker-secret"
  }
}

resource "kubernetes_cluster_role" "diun" {
  depends_on = [kubernetes_namespace.default]
  metadata {
    name = "diun"
  }
  rule {
    api_groups = [""]
    resources  = ["pods"]
    verbs      = ["get", "watch", "list"]
  }
}

resource "kubernetes_cluster_role_binding" "diun" {
  depends_on = [kubernetes_service_account.diun, kubernetes_cluster_role.diun]
  metadata {
    name = "diun"
  }
  role_ref {
    api_group = "rbac.authorization.k8s.io"
    kind      = "ClusterRole"
    name      = "diun"
  }
  subject {
    kind      = "ServiceAccount"
    name      = "diun"
    namespace = "default"
  }
}

resource "kubernetes_deployment" "diun" {
  depends_on = [kubernetes_cluster_role_binding.diun]
  metadata {
    namespace = "default"
    name      = "diun"
  }

  spec {
    selector {
      match_labels = {
        app = "diun"
      }
    }
    template {
      metadata {
        namespace = "default"
        labels = {
          app = "diun"
        }
        annotations = {
          "diun.enable" = "true"
        }
      }
      spec {
        service_account_name = "diun"
        restart_policy       = "Always"
        container {
          name              = "diun"
          image             = "crazymax/diun:latest"
          image_pull_policy = "Always"
          args              = ["serve"]

          env {
            name  = "TZ"
            value = "Europe/Paris"
          }
          env {
            name  = "LOG_LEVEL"
            value = "info"
          }
          env {
            name  = "LOG_JSON"
            value = "false"
          }
          env {
            name  = "DIUN_WATCH_WORKERS"
            value = "20"
          }
          env {
            name  = "DIUN_WATCH_SCHEDULE"
            value = "0 */6 * * *"
          }
          env {
            name  = "DIUN_PROVIDERS_KUBERNETES"
            value = "true"
          }

          volume_mount {
            name       = "data"
            mount_path = "/data"
          }
        }
        volume {
          name = "data"
          host_path {
            type = "Directory"
            path = "/data"
          }
        }
      }
    }
  }
}
