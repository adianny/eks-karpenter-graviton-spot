# ---------------------------------------------------------------------------
# Karpenter and node strategy
#
# These lock in the decisions the assignment actually hinges on: that the
# system node group is Graviton, that Karpenter is pinned rather than
# floating, and that there is a ceiling on how much capacity it may create.
#
#   terraform test -filter=tests/karpenter.tftest.hcl
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

run "system_node_group_runs_on_graviton" {
  command = plan

  # The point of the exercise is price/performance. Running the cluster's own
  # baseline capacity on x86 while telling everyone else to use Graviton would
  # be inconsistent, so this is asserted rather than left to convention.
  assert {
    condition     = can(regex("ARM_64", var.system_node_group.ami_type))
    error_message = "System node group must use an arm64 AMI type - Graviton is the default here."
  }

  assert {
    condition     = can(regex("^m7g|^c7g|^r7g|^m8g|^c8g|^r8g", var.system_node_group.instance_types[0]))
    error_message = "System node group instance types must be Graviton families."
  }
}

run "system_node_group_spans_multiple_azs" {
  command = plan

  # The Karpenter controller lives here. One node means a single point of
  # failure for all provisioning.
  assert {
    condition     = var.system_node_group.min_size >= 2
    error_message = "System node group must keep at least 2 nodes so the Karpenter controller survives a node replacement."
  }

  assert {
    condition     = var.system_node_group.max_size >= var.system_node_group.min_size
    error_message = "max_size must be greater than or equal to min_size."
  }

  # This is the stable floor, not the workload capacity. If it is growing,
  # something is being scheduled here that Karpenter should be handling.
  assert {
    condition     = var.system_node_group.max_size <= 5
    error_message = "System node group should stay small - workloads belong on Karpenter-provisioned capacity."
  }
}

run "karpenter_version_is_pinned_and_compatible" {
  command = plan

  # Kubernetes 1.36 requires Karpenter >= 1.13. Pinning both means the pair is
  # verified rather than hoped for.
  assert {
    condition     = can(regex("^1\\.(1[3-9]|[2-9][0-9])\\.", var.karpenter_chart_version))
    error_message = "Karpenter must be >= 1.13 for Kubernetes 1.36 compatibility."
  }

  assert {
    condition     = !can(regex("(latest|\\*|>=)", var.karpenter_chart_version))
    error_message = "Karpenter version must be an exact pin - an autoscaler is not something to let float."
  }
}

run "capacity_has_a_ceiling" {
  command = plan

  variables {
    node_cpu_limit = 100
  }

  # Without a limit, one misconfigured deployment with large resource requests
  # can provision capacity until the account quota stops it.
  assert {
    condition     = var.node_cpu_limit > 0 && var.node_cpu_limit <= 1000
    error_message = "node_cpu_limit must be a sane positive ceiling."
  }
}

run "production_posture_can_be_selected" {
  command = plan

  # The defaults favour a cheap POC. What matters is that the production
  # posture is reachable by variable rather than by editing code.
  variables {
    single_nat_gateway           = false
    endpoint_public_access       = false
    endpoint_public_access_cidrs = ["10.0.0.0/8"]
  }

  assert {
    condition     = var.single_nat_gateway == false
    error_message = "It must be possible to run one NAT gateway per AZ for production HA."
  }

  assert {
    condition     = var.endpoint_public_access == false
    error_message = "It must be possible to make the API endpoint private-only."
  }

  assert {
    condition     = !contains(var.endpoint_public_access_cidrs, "0.0.0.0/0")
    error_message = "The public endpoint CIDR list must be narrowable away from 0.0.0.0/0."
  }
}
