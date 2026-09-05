# ---------------------------------------------------------------------------
# Network addressing
#
# Subnet maths is worth testing precisely because it is silent when wrong.
# Overlapping ranges or an undersized private tier do not fail the apply -
# they fail months later, when pods stop getting IP addresses and the fix is
# a cluster rebuild.
#
#   terraform test -filter=tests/network.tftest.hcl
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

run "private_subnets_are_large_enough_for_pod_ips" {
  command = plan

  variables {
    vpc_cidr = "10.0.0.0/16"
    az_count = 3
  }

  # /16 split with newbits=4 gives /20s: ~4,091 usable addresses per AZ.
  # The VPC CNI assigns real VPC addresses to pods, so this tier has to be
  # sized for pods, not for nodes.
  assert {
    condition     = cidrsubnet(var.vpc_cidr, 4, 0) == "10.0.0.0/20"
    error_message = "Private subnets must be /20 - anything smaller risks exhausting pod IPs."
  }

  assert {
    condition     = cidrsubnet(var.vpc_cidr, 4, 1) == "10.0.16.0/20"
    error_message = "Second private subnet is not where it should be."
  }

  assert {
    condition     = cidrsubnet(var.vpc_cidr, 4, 2) == "10.0.32.0/20"
    error_message = "Third private subnet is not where it should be."
  }
}

run "public_and_intra_tiers_do_not_collide_with_private" {
  command = plan

  variables {
    vpc_cidr = "10.0.0.0/16"
    az_count = 3
  }

  # Public tier starts at offset 48 (/24s), well clear of the /20s above,
  # which occupy up to 10.0.47.255 when az_count is at its maximum.
  assert {
    condition     = cidrsubnet(var.vpc_cidr, 8, 48) == "10.0.48.0/24"
    error_message = "Public subnets must start at 10.0.48.0/24 to clear the private tier."
  }

  # Intra tier (control plane ENIs, no internet route) starts at 52.
  assert {
    condition     = cidrsubnet(var.vpc_cidr, 8, 52) == "10.0.52.0/24"
    error_message = "Intra subnets must start at 10.0.52.0/24."
  }

  # The gap between public (48-51) and intra (52-55) leaves room for a fourth
  # AZ in each tier without renumbering.
  assert {
    condition     = tonumber(split(".", cidrsubnet(var.vpc_cidr, 8, 52))[2]) - tonumber(split(".", cidrsubnet(var.vpc_cidr, 8, 48))[2]) >= 4
    error_message = "Public and intra tiers must leave at least 4 x /24 of headroom between them."
  }
}

run "addressing_holds_for_a_different_vpc_cidr" {
  command = plan

  variables {
    # Environments get distinct /16s so they can be peered later without
    # renumbering. The maths must not be hardcoded to 10.0.
    vpc_cidr = "10.30.0.0/16"
    az_count = 3
  }

  assert {
    condition     = cidrsubnet(var.vpc_cidr, 4, 0) == "10.30.0.0/20"
    error_message = "Subnet calculation must follow vpc_cidr, not assume 10.0.0.0/16."
  }

  assert {
    condition     = cidrsubnet(var.vpc_cidr, 8, 48) == "10.30.48.0/24"
    error_message = "Public tier offset must follow vpc_cidr."
  }
}

run "two_az_deployment_still_produces_valid_ranges" {
  command = plan

  variables {
    az_count = 2
  }

  assert {
    condition     = cidrsubnet(var.vpc_cidr, 4, 1) == "10.0.16.0/20"
    error_message = "A two-AZ deployment must still allocate valid, distinct ranges."
  }
}
