resource "helm_release" "traefik" {
  namespace  = "default"
  name       = "traefik"
  repository = "https://helm.traefik.io/traefik"
  chart      = "traefik"
  # version    = var.traefik_chart_version

  # Helm chart deployment can sometimes take longer than the default 5 minutes
  timeout = 800

  // cf. https://github.com/traefik/traefik-helm-chart/blob/master/traefik/values.yaml
  # values = [
  #   <<-EOF
  #   deployment:
  #     kind: DaemonSet
  #   ingressClass:
  #     enabled: true
  #     isDefaultClass: true
  #   service:
  #     type: "NodePort"
  #   providers:
  #     kubernetesIngress:
  #       enabled: true
  #       ingressEndpoint:
  #         hostname: "90dy.me"
  #         publishedService: "default/ccxt"
  #       namespace: ["default"]
  #       publishedService:
  #         enabled: true
  #   EOF
  # ]
  set {
    name  = "providers.kubernetesIngress.hostname"
    value = "90dy.me"
  }
  set {
    name  = "providers.kubernetesIngress.publishedService.enabled"
    value = true
  }
}
