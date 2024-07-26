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

