terraform {
  backend "pg" {}
}

variable "heroku_team" {}
variable "heroku_private_space" {}
variable "heroku_region" {}
variable "kong_app_name" {}

locals {
  kong_base_url  = "https://${var.kong_app_name}.herokuapp.com"
  kong_admin_uri = "${local.kong_base_url}/kong-admin"
}

provider "heroku" {
  version = "~> 1.5"
}

provider "kong" {
  version = "~> 1.7"

  # Optional: use insecure until DNS is ready at dnsimple
  # kong_admin_uri = "${local.kong_insecure_admin_uri}"
  kong_admin_uri = "${local.kong_admin_uri}"

  kong_api_key = "${random_id.kong_admin_api_key.b64_url}"
}

provider "random" {
  version = "~> 2.0"
}

resource "random_id" "kong_admin_api_key" {
  byte_length = 32
} 

# Proxy app

resource "heroku_app" "kong" {
  name   = "${var.kong_app_name}"
  space  = "${var.heroku_private_space}"
  region = "${var.heroku_region}"

  config_vars {
    KONG_HEROKU_ADMIN_KEY = "${random_id.kong_admin_api_key.b64_url}"
  }

  organization {
    name = "${var.heroku_team}"
  }
}

resource "heroku_addon" "kong_pg" {
  app  = "${heroku_app.kong.name}"
  plan = "heroku-postgresql:private-0"
}

resource "heroku_slug" "kong" {
  app                            = "${heroku_app.kong.id}"
  buildpack_provided_description = "Kong"
  file_path                      = "slugs/heroku-kong-v6.0.1.tgz"

  process_types = {
    release = "bin/heroku-buildpack-kong-release"
    web     = "bin/heroku-buildpack-kong-web"
  }
}

resource "heroku_app_release" "kong" {
  app     = "${heroku_app.kong.name}"
  slug_id = "${heroku_slug.kong.id}"

  depends_on = ["heroku_addon.kong_pg"]
}

resource "heroku_formation" "kong" {
  app        = "${heroku_app.kong.name}"
  type       = "web"
  quantity   = 1
  size       = "Private-S"
  depends_on = ["heroku_app_release.kong"]

  provisioner "local-exec" {
    command = "./bin/kong-health-check ${local.kong_base_url}/kong-admin"
  }
}

# Heroku API rate limiter proxy
resource "kong_service" "heroku_api" {
  name       = "heroku-api"
  protocol   = "https"
  host       = "api.heroku.com"
  port       = 443
  depends_on = ["heroku_formation.kong"]
}

resource "kong_route" "web_root" {
  protocols  = ["https"]
  paths      = ["/"]
  service_id = "${kong_service.heroku_api.id}"
}

resource "kong_plugin" "heroku_api_rate_limit" {
  name       = "rate-limiting"
  service_id = "${kong_service.heroku_api.id}"

  config = {
    minute = 5
  }
}

output "kong_app_url" {
  value = "https://${heroku_app.kong.name}.herokuapp.com"
}
