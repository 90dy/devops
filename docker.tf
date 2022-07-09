variable "DOCKER_USERNAME" { type = string }
variable "DOCKER_ACCESS_TOKEN" { type = string }

resource "kubernetes_secret" "_90dy_docker_config" {
  depends_on = [kubernetes_namespace._90dy_namespace]

  metadata {
    namespace = "90dy"
    name      = "docker-secret"
  }

  data = {
    ".dockerconfigjson" = <<-EOF
			{
				"auths": {
					"docker.io": {
						"username": "${var.DOCKER_USERNAME}",
						"password": "${var.DOCKER_ACCESS_TOKEN}"
					}
				}
			}
		EOF
  }

  type = "kubernetes.io/dockerconfigjson"
}
