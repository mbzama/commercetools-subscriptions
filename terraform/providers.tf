terraform {
  required_version = ">= 1.3.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
    commercetools = {
      source  = "labd/commercetools"
      version = "~> 1.10"
    }
  }
}

provider "aws" {
  region = var.aws_region
}

provider "commercetools" {
  project_key   = var.ct_project_key
  client_id     = var.ct_client_id
  client_secret = var.ct_client_secret
  scopes        = var.ct_scopes
  api_url       = var.ct_api_url
  token_url     = var.ct_auth_url
}
