variable "username" { type = string }
variable "access_token" { type = string }

resource "kubernetes_secret" "default_docker_config" {
  # depends_on = [kubernetes_namespace.default_namespace]

  metadata {
    namespace = "default"
    name      = "docker-secret"
  }

  data = {
    ".dockerconfigjson" = <<-EOF
			{
				"auths": {
					"docker.io": {
						"username": "${var.username}",
						"password": "${var.access_token}"
					}
				}
			}
		EOF
  }

  type = "kubernetes.io/dockerconfigjson"
}
