output "cluster_name" {
  description = "EKS cluster name."
  value       = module.eks.cluster_name
}

output "cluster_endpoint" {
  description = "Kubernetes API server endpoint."
  value       = module.eks.cluster_endpoint
}

output "cluster_version" {
  description = "Kubernetes version running on the control plane."
  value       = module.eks.cluster_version
}

output "configure_kubectl" {
  description = "Run this to point kubectl at the new cluster."
  value       = "aws eks update-kubeconfig --region ${var.region} --name ${module.eks.cluster_name}"
}

output "vpc_id" {
  description = "ID of the dedicated VPC."
  value       = module.vpc.vpc_id
}

output "private_subnets" {
  description = "Private subnets where nodes and pods run."
  value       = module.vpc.private_subnets
}

output "karpenter_node_iam_role_name" {
  description = "IAM role assumed by Karpenter-provisioned nodes; referenced by the EC2NodeClass."
  value       = module.karpenter.node_iam_role_name
}

output "karpenter_interruption_queue" {
  description = "SQS queue receiving Spot interruption and rebalance notices."
  value       = module.karpenter.queue_name
}

output "try_it" {
  description = "Quickest way to see multi-architecture scheduling actually work."
  value       = <<-EOT

    1. Point kubectl at the cluster:
       aws eks update-kubeconfig --region ${var.region} --name ${module.eks.cluster_name}

    2. Schedule a workload on Graviton:
       kubectl apply -f examples/01-graviton-arm64.yaml

    3. Watch Karpenter provision an arm64 node (~40s):
       kubectl get nodes -L kubernetes.io/arch,karpenter.sh/capacity-type -w

    4. Confirm the pod really is on arm64:
       kubectl logs -l app=hello-graviton --tail=5

  EOT
}
