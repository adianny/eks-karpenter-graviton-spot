# ---------------------------------------------------------------------------
# Input validation
#
# These run against the validation blocks in variables.tf. They are cheap,
# need no credentials, and catch the class of mistake that would otherwise
# surface fifteen minutes into an apply.
#
#   terraform test -filter=tests/variables.tftest.hcl
# ---------------------------------------------------------------------------

# Mocked providers: these tests run entirely offline, with no AWS credentials
# and no API calls, so they are safe in CI and cost nothing.
#
# The data sources below need coherent values rather than generated ones -
# an IAM policy document has to be valid JSON, and the AZ lookup has to
# return enough zones to slice.
mock_provider "aws" {
  mock_data "aws_iam_policy_document" {
    defaults = {
      json = jsonencode({ Version = "2012-10-17", Statement = [] })
    }
  }

  mock_data "aws_availability_zones" {
    defaults = {
      names = ["eu-west-1a", "eu-west-1b", "eu-west-1c", "eu-west-1d"]
    }
  }

  mock_data "aws_ecrpublic_authorization_token" {
    defaults = {
      user_name = "AWS"
      password  = "mock-token"
    }
  }

  mock_data "aws_partition" {
    defaults = {
      partition  = "aws"
      dns_suffix = "amazonaws.com"
      id         = "aws"
    }
  }

  mock_data "aws_caller_identity" {
    defaults = {
      account_id = "123456789012"
      arn        = "arn:aws:iam::123456789012:user/test"
      id         = "123456789012"
      user_id    = "AIDATEST"
    }
  }

  mock_data "aws_region" {
    defaults = {
      name   = "eu-west-1"
      id     = "eu-west-1"
      region = "eu-west-1"
    }
  }

  mock_data "aws_iam_session_context" {
    defaults = {
      issuer_arn  = "arn:aws:iam::123456789012:role/test-runner"
      issuer_id   = "AROATEST"
      issuer_name = "test-runner"
    }
  }
}

mock_provider "helm" {}

# --- name -------------------------------------------------------------------

run "name_rejects_uppercase" {
  command = plan

  variables {
    name = "Demo-EKS"
  }

  expect_failures = [var.name]
}

run "name_rejects_leading_digit" {
  command = plan

  variables {
    name = "1demo"
  }

  expect_failures = [var.name]
}

run "name_rejects_too_short" {
  command = plan

  variables {
    name = "ab"
  }

  expect_failures = [var.name]
}

run "name_accepts_valid" {
  command = plan

  variables {
    name = "demo-eks-karpenter"
  }

  assert {
    condition     = var.name == "demo-eks-karpenter"
    error_message = "A valid lowercase hyphenated name should be accepted."
  }
}

# --- vpc_cidr ---------------------------------------------------------------

run "vpc_cidr_rejects_garbage" {
  command = plan

  variables {
    vpc_cidr = "not-a-cidr"
  }

  expect_failures = [var.vpc_cidr]
}

# --- az_count ---------------------------------------------------------------

run "az_count_rejects_single_az" {
  command = plan

  variables {
    # EKS requires at least two AZs; one would fail at apply time with a much
    # less obvious error.
    az_count = 1
  }

  expect_failures = [var.az_count]
}

run "az_count_rejects_excessive" {
  command = plan

  variables {
    az_count = 8
  }

  expect_failures = [var.az_count]
}

# --- defaults ---------------------------------------------------------------

run "defaults_are_sane" {
  command = plan

  assert {
    condition     = var.az_count == 3
    error_message = "Default AZ count should be 3 - two is the EKS minimum, not a production default."
  }

  assert {
    condition     = var.kubernetes_version == "1.36"
    error_message = "Default Kubernetes version should be the latest EKS offers."
  }

  assert {
    condition     = var.karpenter_chart_version == "1.14.1"
    error_message = "Karpenter chart version must be pinned explicitly, never floating."
  }

  assert {
    condition     = var.node_cpu_limit > 0
    error_message = "A vCPU ceiling must be set - it is the guardrail against an unbounded bill."
  }
}
