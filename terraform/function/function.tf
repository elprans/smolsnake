# Copyright Contributors to the smolsnake project.
#
# SPDX-License-Identifier: 0BSD

data "terraform_remote_state" "infra" {
  backend = "local"

  config = {
    path = "${path.module}/../depcache/terraform.tfstate"
  }
}

locals {
  infra = data.terraform_remote_state.infra.outputs
}

provider "aws" {
  region = local.infra.region

  default_tags {
    tags = {
      terraform = "true"
      smolsnake = "true"
    }
  }
}

resource "external" "lambda_package" {
  triggers = {
    dir_sha = sha1(join(
      "",
      [
        for f in fileset(var.function_source, "*") :
        filesha1("${var.function_source}/${f}")
      ],
    ))
  }

  program = ["${path.module}/scripts/build_lambda_function.sh"]
  query = {
    region             = local.infra.region
    func_dir           = var.function_source
    request_queue_url  = local.infra.cache_queues.request
    response_queue_url = local.infra.cache_queues.response
    python_version     = var.python_version
  }
}

resource "aws_lambda_function" "function" {
  filename         = external.lambda_package.result.package
  function_name    = var.function_name
  role             = local.infra.roles.lambda
  handler          = "lambda_function.lambda_handler"
  source_code_hash = external.lambda_package.result.hash
  runtime          = "python${var.python_version}"

  file_system_config {
    arn              = local.infra.efs.access_point_arn
    local_mount_path = "/mnt/efs"
  }

  vpc_config {
    subnet_ids         = local.infra.net.subnet_ids
    security_group_ids = local.infra.net.security_group_ids
  }
}

output "function_name" {
  value = aws_lambda_function.function.function_name
}

output "last_modified" {
  value = aws_lambda_function.function.last_modified
}
