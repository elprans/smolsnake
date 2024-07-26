terraform {
  required_version = ">= 1.3"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "5.54.1"
    }
  }
}

provider "aws" {
  region = "us-west-2"

  default_tags {
    tags = {
      terraform = "true"
      smolsnake = "true"
    }
  }
}
