# Copyright Contributors to the smolsnake project.
#
# SPDX-License-Identifier: 0BSD

terraform {
  required_version = ">= 1.3"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "5.54.1"
    }
    external = {
      source  = "edgedb/external"
      version = "3.2.1"
    }
  }
}

provider "aws" {
  region = "us-west-2"
}

module "function" {
  source          = "../../terraform/function"
  python_version  = "3.12"
  function_source = "${path.module}/src"
  function_name   = "smolsnake-test1"
}

resource "aws_lambda_invocation" "test" {
  function_name = module.function.function_name
  input         = jsonencode({})
  triggers = {
    lambda_mtime = module.function.last_modified
  }
}
