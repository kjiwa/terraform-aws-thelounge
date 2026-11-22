terraform {
  required_version = ">= 1.15"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 6.45"
    }
    dns = {
      source  = "hashicorp/dns"
      version = ">= 3.4"
    }
  }
}
