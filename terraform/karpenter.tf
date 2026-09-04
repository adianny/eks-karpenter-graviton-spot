################################################################################
# Karpenter — supporting AWS resources
#
# The upstream submodule creates what Karpenter needs on the AWS side:
#   - the controller IAM role, associated via EKS Pod Identity
#   - the node IAM role and instance profile
#   - an SQS queue plus the EventBridge rules that feed it
#
# That last part is what makes Spot safe. AWS publishes a two-minute warning
# before reclaiming a Spot instance; those events land in the queue, Karpenter
# reads them and cordons and drains the node before it disappears. Without the
# queue, Spot reclamation is an abrupt pod kill.
################################################################################

module "karpenter" {
  source  = "terraform-aws-modules/eks/aws//modules/karpenter"
  version = "~> 21.0"

  cluster_name = module.eks.cluster_name

  # EKS Pod Identity rather than IRSA. Pod Identity is the current mechanism:
  # no OIDC trust policy to maintain and no per-cluster IAM plumbing.
  create_pod_identity_association = true

  # The node role name is referenced by the EC2NodeClass, so it must be
  # predictable rather than suffixed.
  node_iam_role_use_name_prefix = false
  node_iam_role_name            = var.name

  node_iam_role_additional_policies = {
    # SSM lets an operator open a session on a node without SSH, a bastion,
    # or an inbound rule. Access is logged in CloudTrail.
    AmazonSSMManagedInstanceCore = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
  }

  tags = local.tags
}

################################################################################
# Karpenter — controller
################################################################################

resource "helm_release" "karpenter" {
  name             = "karpenter"
  namespace        = "kube-system"
  create_namespace = false

  repository          = "oci://public.ecr.aws/karpenter"
  repository_username = data.aws_ecrpublic_authorization_token.token.user_name
  repository_password = data.aws_ecrpublic_authorization_token.token.password
  chart               = "karpenter"
  version             = var.karpenter_chart_version

  wait = true

  values = [yamlencode({
    # Pin the controller to the managed node group. Karpenter must not run on
    # a node it could itself consolidate away.
    nodeSelector = {
      "karpenter.sh/controller" = "true"
    }

    # Karpenter needs to resolve AWS endpoints before CoreDNS is necessarily
    # ready on a fresh cluster.
    dnsPolicy = "Default"

    settings = {
      clusterName       = module.eks.cluster_name
      clusterEndpoint   = module.eks.cluster_endpoint
      interruptionQueue = module.karpenter.queue_name

      # Drains nodes ahead of an AWS-signalled zonal shift instead of losing
      # them mid-request.
      enableZonalShift = true
    }

    # The controller is a singleton with a leader election; two replicas across
    # AZs so a node replacement does not pause all provisioning.
    replicas = 2

    controller = {
      resources = {
        requests = { cpu = "500m", memory = "512Mi" }
        limits   = { memory = "512Mi" } # no CPU limit: throttling the scheduler is counterproductive
      }
    }

    # The webhook is unnecessary on the v1 API.
    webhook = { enabled = false }
  })]

  depends_on = [module.eks]
}

################################################################################
# Karpenter — NodePools and EC2NodeClass
#
# Shipped as a small local chart rather than kubernetes_manifest resources.
# kubernetes_manifest reads the CRD schema at plan time, which means a plan
# against a cluster that does not exist yet fails - it cannot be used in the
# same apply that creates the cluster. Helm has no such requirement, so the
# whole stack comes up in a single `terraform apply`.
################################################################################

resource "helm_release" "karpenter_nodepools" {
  name      = "karpenter-nodepools"
  namespace = "kube-system"
  chart     = "${path.module}/charts/karpenter-nodepools"

  values = [yamlencode({
    clusterName     = module.eks.cluster_name
    nodeIamRoleName = module.karpenter.node_iam_role_name
    discoveryTag    = var.name
    cpuLimit        = var.node_cpu_limit
  })]

  # The CRDs ship with the controller chart, so they must exist first.
  depends_on = [helm_release.karpenter]
}
