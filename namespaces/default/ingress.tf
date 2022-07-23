variable "CCXT_PORT" { type = string }

resource "kubernetes_ingress_v1" "ingress" {
  metadata {
    namespace = "default"
    name      = "ingress"
    annotations = {
      "kubernetes.io/tls-acme" : "true"
      "kubernetes.io/ingress.class" : "nginx"
      "external-dns.alpha.kubernetes.io/hostname" = "ccxt.90dy.me"
    }
  }
  spec {
    tls {
      secret_name = "ingress-tls"
    }
    rule {
      host = "ccxt.90dy.me"
      http {
        path {
          backend {
            service {
              name = "ccxt"
              port {
                number = var.CCXT_PORT
              }
            }
          }
        }
      }
    }
  }
}
