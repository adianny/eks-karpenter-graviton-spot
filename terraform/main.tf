data "aws_availability_zones" "available" {
  # Local Zones and Wavelength Zones cannot host EKS nodes.
  filter {
    name   = "opt-in-status"
    values = ["opt-in-not-required"]
  }
}

locals {
  azs = slice(data.aws_availability_zones.available.names, 0, var.az_count)

  tags = merge(
    {
      Project     = var.name
      ManagedBy   = "terraform"
      Environment = "poc"
    },
    var.tags,
  )
}

################################################################################
# Network — a dedicated VPC
#
# Subnet sizing is the decision that is expensive to get wrong. The VPC CNI
# hands every pod a real VPC address, so the private tier is sized generously:
# a /20 per AZ is ~4,000 addresses, which is room to grow into. Running out of
# pod IPs is not a config change, it is a cluster rebuild.
################################################################################

module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "~> 6.0"

  name = var.name
  cidr = var.vpc_cidr
  azs  = local.azs

  # Compute nodes and pods. Large blocks - see note above.
  private_subnets = [for i, _ in local.azs : cidrsubnet(var.vpc_cidr, 4, i)]

  # Load balancers and NAT gateways only. Nothing else gets a public address.
  public_subnets = [for i, _ in local.azs : cidrsubnet(var.vpc_cidr, 8, i + 48)]

  # Control plane ENIs, isolated: no route to the internet at all.
  intra_subnets = [for i, _ in local.azs : cidrsubnet(var.vpc_cidr, 8, i + 52)]

  enable_nat_gateway = true
  single_nat_gateway = var.single_nat_gateway

  enable_dns_hostnames = true
  enable_dns_support   = true

  # Flow logs are the only way to answer "what talked to what" after the fact.
  enable_flow_log                                 = true
  create_flow_log_cloudwatch_log_group            = true
  create_flow_log_cloudwatch_iam_role             = true
  flow_log_max_aggregation_interval               = 60
  flow_log_cloudwatch_log_group_retention_in_days = 7

  public_subnet_tags = {
    # Tells the AWS Load Balancer Controller where to place internet-facing LBs.
    "kubernetes.io/role/elb" = 1
  }

  private_subnet_tags = {
    "kubernetes.io/role/internal-elb" = 1

    # Karpenter finds the subnets to launch into by this tag. Without it,
    # Karpenter provisions nothing and the failure mode is a silent pending pod.
    "karpenter.sh/discovery" = var.name
  }

  tags = local.tags
}

################################################################################
# VPC endpoints
#
# Not cosmetic. Every image pull and secret fetch would otherwise traverse the
# NAT gateway at $0.045/GB. On a cluster that pulls images continuously these
# endpoints pay for themselves, and the traffic never leaves the AWS backbone.
################################################################################

module "vpc_endpoints" {
  source  = "terraform-aws-modules/vpc/aws//modules/vpc-endpoints"
  version = "~> 6.0"

  vpc_id = module.vpc.vpc_id

  # Gateway endpoints are free. There is no reason not to have them.
  endpoints = merge(
    {
      s3 = {
        service         = "s3"
        service_type    = "Gateway"
        route_table_ids = flatten([module.vpc.private_route_table_ids, module.vpc.intra_route_table_ids])
        tags            = { Name = "${var.name}-s3" }
      }
    },
    # Interface endpoints cost ~$7/month each; these are the ones an EKS
    # cluster actually hammers.
    { for svc in ["ecr.api", "ecr.dkr", "sts", "secretsmanager", "logs", "ec2"] :
      replace(svc, ".", "_") => {
        service             = svc
        private_dns_enabled = true
        subnet_ids          = module.vpc.private_subnets
        tags                = { Name = "${var.name}-${svc}" }
      }
    },
  )

  create_security_group      = true
  security_group_name_prefix = "${var.name}-vpce-"
  security_group_rules = {
    ingress_https = {
      description = "HTTPS from within the VPC"
      type        = "ingress"
      from_port   = 443
      to_port     = 443
      protocol    = "tcp"
      cidr_blocks = [module.vpc.vpc_cidr_block]
    }
  }

  tags = local.tags
}

################################################################################
# EKS cluster
################################################################################

module "eks" {
  source  = "terraform-aws-modules/eks/aws"
  version = "~> 21.0"

  name               = var.name
  kubernetes_version = var.kubernetes_version

  # Grants the identity running Terraform cluster-admin, so the Helm releases
  # below can be applied in the same run. Uses EKS Access Entries - the
  # aws-auth ConfigMap is deprecated and not used here.
  enable_cluster_creator_admin_permissions = true

  endpoint_public_access       = var.endpoint_public_access
  endpoint_public_access_cidrs = var.endpoint_public_access_cidrs
  endpoint_private_access      = true

  # Audit and authenticator logs are what turn "something happened" into an
  # actual answer. Cheap; enable them from the start.
  enabled_log_types = ["api", "audit", "authenticator"]

  # Envelope-encrypt Kubernetes secrets with a dedicated KMS key.
  encryption_config = {
    resources = ["secrets"]
  }

  # ARC zonal shift. When AWS reports an impaired Availability Zone, traffic is
  # moved away from it automatically. This has to be enabled on the cluster
  # itself, not only in Karpenter: the controller calls GetManagedResource at
  # startup and refuses to run against a cluster that is not registered, which
  # is the correct behaviour - it will not pretend to respect a shift it cannot
  # observe. Registering here is what lets Karpenter stop provisioning into a
  # zone that is being drained.
  zonal_shift_config = {
    enabled = true
  }

  addons = {
    coredns    = {}
    kube-proxy = {}

    # before_compute: these have to exist before any node joins, or the first
    # nodes come up without working networking / identity.
    vpc-cni = {
      before_compute = true
      configuration_values = jsonencode({
        env = {
          # Prefix delegation multiplies the number of pod IPs a node can
          # assign, which is what keeps larger instance types from being
          # IP-bound rather than CPU-bound.
          ENABLE_PREFIX_DELEGATION = "true"
          WARM_PREFIX_TARGET       = "1"
        }
      })
    }
    eks-pod-identity-agent = {
      before_compute = true
    }

    metrics-server = {}

    # Deliberately not installed: aws-ebs-csi-driver.
    #
    # Nothing here claims a PersistentVolume, and the driver's controller needs
    # its own IAM identity to talk to the EBS API - without one it sits in
    # CrashLoopBackOff and the add-on never reports ACTIVE, which fails the
    # apply on a cluster that is otherwise healthy. When stateful workloads
    # arrive, add it back together with the role it needs:
    #
    #   aws-ebs-csi-driver = {
    #     pod_identity_association = [{
    #       role_arn        = aws_iam_role.ebs_csi.arn   # AmazonEBSCSIDriverPolicy
    #       service_account = "ebs-csi-controller-sa"
    #     }]
    #   }
  }

  vpc_id                   = module.vpc.vpc_id
  subnet_ids               = module.vpc.private_subnets
  control_plane_subnet_ids = module.vpc.intra_subnets

  ############################################################################
  # System node group
  #
  # Small, On-Demand, and Graviton. Hosts the Karpenter controller and other
  # cluster-critical components. Everything else is provisioned by Karpenter.
  ############################################################################
  eks_managed_node_groups = {
    system = {
      ami_type       = var.system_node_group.ami_type
      instance_types = var.system_node_group.instance_types

      min_size     = var.system_node_group.min_size
      max_size     = var.system_node_group.max_size
      desired_size = var.system_node_group.desired_size

      labels = {
        # Karpenter's own pods are pinned here via nodeSelector, guaranteeing
        # the controller never runs on a node it manages.
        "karpenter.sh/controller" = "true"
      }

      # Reserve this group for cluster-critical components. Without the taint,
      # application pods land here whenever it happens to have room - which
      # silently defeats the whole point: workloads end up on fixed On-Demand
      # capacity instead of the Spot capacity Karpenter would have bought them.
      #
      # CriticalAddonsOnly is the conventional key precisely because CoreDNS,
      # metrics-server and the Karpenter chart all tolerate it out of the box.
      taints = {
        critical_addons_only = {
          key    = "CriticalAddonsOnly"
          value  = "true"
          effect = "NO_SCHEDULE"
        }
      }
    }
  }

  # Karpenter discovers the security group to attach to new nodes by this tag.
  # Exactly one security group in the account should carry it.
  node_security_group_tags = merge(local.tags, {
    "karpenter.sh/discovery" = var.name
  })

  tags = local.tags
}
