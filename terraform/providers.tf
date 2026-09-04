provider "aws" {
  region = var.region

  default_tags {
    tags = local.tags
  }
}

# Karpenter's Helm chart is published to ECR Public, which needs an auth token.
# ECR Public tokens are only issued from us-east-1 regardless of where the
# cluster lives.
data "aws_ecrpublic_authorization_token" "token" {
  region = "us-east-1"
}

# NOTE ON PROVIDER v3
# The helm provider changed shape in v3: `kubernetes` is now an attribute
# (`kubernetes = { ... }`) rather than a nested block (`kubernetes { ... }`).
# Configurations written against v2 will fail to parse here.
provider "helm" {
  kubernetes = {
    host                   = module.eks.cluster_endpoint
    cluster_ca_certificate = base64decode(module.eks.cluster_certificate_authority_data)

    # Tokens are minted at apply time rather than stored in state.
    exec = {
      api_version = "client.authentication.k8s.io/v1beta1"
      command     = "aws"
      args        = ["eks", "get-token", "--cluster-name", module.eks.cluster_name, "--region", var.region]
    }
  }
}
