variable "PROVIDER" { type = string }

variable "KUBE_CONFIG_PATH" { type = string }

variable "DOCKER_USERNAME" { type = string }
variable "DOCKER_ACCESS_TOKEN" { type = string }

variable "SCW_ACCESS_KEY" { type = string }
variable "SCW_SECRET_KEY" { type = string }
variable "SCW_DEFAULT_ORGANIZATION_ID" { type = string }

variable "CCXT_PORT" { type = string }

terraform {
  backend "kubernetes" {
    secret_suffix    = "state"
    load_config_file = true
  }
}

provider "kubernetes" {
  config_path = var.KUBE_CONFIG_PATH
}
provider "helm" {
  kubernetes {
    config_path = var.KUBE_CONFIG_PATH
  }
}

module "namespace_default" {
  source              = "./namespaces/default"
  DOCKER_USERNAME     = var.DOCKER_USERNAME
  DOCKER_ACCESS_TOKEN = var.DOCKER_ACCESS_TOKEN
}

module "provider_scaleway" {
  source = "./providers/scaleway"
  count  = var.PROVIDER == "scaleway" ? 1 : 0
  depends_on = [
    module.namespace_default
  ]

  SCW_ACCESS_KEY              = var.SCW_ACCESS_KEY
  SCW_SECRET_KEY              = var.SCW_SECRET_KEY
  SCW_DEFAULT_ORGANIZATION_ID = var.SCW_DEFAULT_ORGANIZATION_ID
}

module "app_ccxt" {
  source = "./apps/ccxt"

  depends_on = [
    module.namespace_default
  ]

  CCXT_PORT = var.CCXT_PORT
}
