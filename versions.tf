terraform {
  required_version = ">= 1.15"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 6.45"
      # CloudFront only accepts ACM certificates from us-east-1, whatever the
      # default provider's region is.
      configuration_aliases = [aws.us_east_1]
    }
  }
}
