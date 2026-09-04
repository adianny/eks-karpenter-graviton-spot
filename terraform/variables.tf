variable "name" {
  description = "Name prefix applied to the cluster and every resource created alongside it."
  type        = string
  default     = "demo-eks-karpenter"

  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{2,38}$", var.name))
    error_message = "Name must be lowercase alphanumeric with hyphens, start with a letter, and be 3-39 characters."
  }
}

variable "region" {
  description = "AWS region to deploy into."
  type        = string
  default     = "eu-west-1"
}

variable "kubernetes_version" {
  description = <<-EOT
    EKS control plane version.

    Defaults to the newest version AWS offers, as the assignment asks for the
    latest available. Note that for a real production cluster the usual advice
    is to run N-1: it gives the ecosystem (CNI, CSI drivers, operators) time to
    certify against a new minor before you depend on it.
  EOT
  type        = string
  default     = "1.36"
}

variable "vpc_cidr" {
  description = "CIDR block for the dedicated VPC. Must be large enough for pod IPs - the VPC CNI assigns real VPC addresses to pods."
  type        = string
  default     = "10.0.0.0/16"

  validation {
    condition     = can(cidrnetmask(var.vpc_cidr))
    error_message = "vpc_cidr must be a valid IPv4 CIDR block."
  }
}

variable "az_count" {
  description = "Number of Availability Zones to spread across. Three is the production default; two is the EKS minimum."
  type        = number
  default     = 3

  validation {
    condition     = var.az_count >= 2 && var.az_count <= 4
    error_message = "az_count must be between 2 and 4."
  }
}

variable "single_nat_gateway" {
  description = <<-EOT
    Use one NAT gateway for the whole VPC instead of one per AZ.

    true  - cheaper (~$32/month saved per AZ), but a single AZ failure severs
            egress for the entire cluster. Fine for a POC or a dev environment.
    false - one per AZ. Correct for production.
  EOT
  type        = bool
  default     = true
}

variable "system_node_group" {
  description = <<-EOT
    The small managed node group that hosts cluster-critical components
    (the Karpenter controller itself, CoreDNS, metrics).

    Karpenter cannot provision the node it runs on, and components that keep
    the cluster alive should not sit on capacity that Karpenter may consolidate
    away or that Spot may reclaim. This is that stable floor - deliberately
    small, On-Demand, and on Graviton.
  EOT
  type = object({
    instance_types = optional(list(string), ["m7g.large"])
    ami_type       = optional(string, "BOTTLEROCKET_ARM_64")
    min_size       = optional(number, 2)
    max_size       = optional(number, 3)
    desired_size   = optional(number, 2)
  })
  default = {}
}

variable "karpenter_chart_version" {
  description = "Karpenter Helm chart version. Pinned deliberately - autoscaling is not something you want silently upgrading."
  type        = string
  default     = "1.14.1"
}

variable "node_cpu_limit" {
  description = "Ceiling on total vCPUs Karpenter may provision. A guardrail against a runaway workload provisioning an unbounded bill."
  type        = number
  default     = 100
}

variable "endpoint_public_access" {
  description = "Expose the Kubernetes API endpoint publicly. Convenient for a POC; production should restrict this to known CIDRs or go private-only."
  type        = bool
  default     = true
}

variable "endpoint_public_access_cidrs" {
  description = "CIDRs allowed to reach the public API endpoint. Narrow this to your office/VPN ranges for anything real."
  type        = list(string)
  default     = ["0.0.0.0/0"]
}

variable "tags" {
  description = "Additional tags applied to every resource."
  type        = map(string)
  default     = {}
}
