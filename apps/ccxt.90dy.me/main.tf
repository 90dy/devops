# external-dns.alpha.kubernetes.io/hostname: my-app.example.com
variable "CCXT_PORT" { type = string }
resource "kubernetes_ingress_v1" "ccxt" {
  metadata {
    namespace = "default"
    name      = "ccxt"
  }
  spec {
    # tls {
    # secret_name = "ingress-tls"
    # }
    rule {
      host = "ccxt.90dy.me"
      http {
        path {
          path      = "/"
          path_type = "Prefix"
          backend {
            service {
              name = "ccxt"
              port {
                name = "ccxt"
              }
            }
          }
        }
      }
    }
  }
}
resource "kubernetes_service" "ccxt" {
  metadata {
    namespace = "default"
    name      = "ccxt"
    # annotations = {
    #   "external-dns.alpha.kubernetes.io/hostname" = "ccxt.90dy.me"
    # }
  }
  spec {
    # type             = contains(["scaleway"], var.TARGET) ? "LoadBalancer" : "NodePort"
    selector = {
      app = "ccxt"
    }
    port {
      name        = "ccxt"
      port        = 80
      target_port = 3000
    }
  }
}

# resource "kubernetes_horizontal_pod_autoscaler" "default_autoscaler" {
#   metadata {
#     namespace = "default"
#     name      = "autoscaler"
#     labels = {
#       type = "autoscaler"
#     }
#   }
#   spec {
#     max_replicas = 10
#     min_replicas = 1
#     scale_target_ref {
#       kind = "Deployment"
#       name = "ccxt"
#     }
#     metric {
#       type = "Resource"
#       resource {
#         name = "cpu"
#         target {
#           type                = "Utilization"
#           average_utilization = "62"
#         }
#       }
#     }
#   }
# }

resource "kubernetes_deployment" "ccxt" {
  depends_on = [
    kubernetes_service.ccxt,
  ]
  metadata {
    namespace = "default"
    name      = "ccxt"
  }
  timeouts {
    create = "2m"
  }
  spec {
    selector {
      match_labels = {
        app = "ccxt"
      }
    }
    template {
      metadata {
        namespace = "default"
        labels = {
          app = "ccxt"
        }
      }
      spec {
        container {
          name              = "ccxt"
          image             = "90dy/ccxt-app:latest"
          image_pull_policy = "Always"
          port {
            name           = "ccxt"
            container_port = 3000
          }
        }
      }
    }
  }
}
