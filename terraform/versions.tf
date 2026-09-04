terraform {
  # 1.5.7 is the floor required by the upstream EKS module; anything newer works.
  required_version = ">= 1.5.7"

  required_providers {
    aws = {
      source = "hashicorp/aws"
      # >= 6.59 is required by terraform-aws-modules/eks v21.
      version = "~> 6.59"
    }
    helm = {
      source = "hashicorp/helm"
      # v3 changed provider configuration from nested blocks to attributes.
      # Pinned to the major to avoid a silent breaking change on init.
      version = "~> 3.0"
    }
  }

  # ---------------------------------------------------------------------------
  # Remote state
  #
  # Left commented so the repository can be cloned and applied without any
  # pre-existing infrastructure. For anything beyond a throwaway POC this
  # should be enabled: local state has no locking and no history, which is how
  # two engineers end up destroying each other's work.
  #
  # backend "s3" {
  #   bucket       = "<your-tf-state-bucket>"
  #   key          = "eks-karpenter/terraform.tfstate"
  #   region       = "eu-west-1"
  #   encrypt      = true
  #   use_lockfile = true   # S3-native locking; DynamoDB table no longer needed
  # }
  # ---------------------------------------------------------------------------
}
