variable "region" {
  description = "AWS region"
  type        = string
  default     = "us-east-1"
}

variable "cluster_name" {
  description = "EKS cluster name (also used as the ExternalDNS owner id)"
  type        = string
  default     = "platform"
}

variable "kubernetes_version" {
  description = "EKS Kubernetes version"
  type        = string
  default     = "1.36"
}

variable "domain" {
  description = "Public Route 53 hosted zone. Apps get <name>-<env>.<domain> (prod: <name>.<domain>)"
  type        = string
}

variable "vpc_cidr" {
  description = "CIDR of the new VPC"
  type        = string
  default     = "10.0.0.0/16"
}

variable "node_instance_types" {
  description = "Instance types of the managed node group"
  type        = list(string)
  default     = ["t3.large"]
}

variable "node_min_size" {
  type    = number
  default = 2
}

variable "node_desired_size" {
  type    = number
  default = 3
}

variable "node_max_size" {
  type    = number
  default = 5
}

variable "gitops_repo_url" {
  description = "Git repository ArgoCD watches for app requests (eks-full-infra/apps/*.yaml)"
  type        = string
  default     = "https://github.com/utrains/kubernetes-practice2.git"
}

variable "gitops_revision" {
  description = "Branch, tag or commit of gitops_repo_url"
  type        = string
  default     = "main"
}

variable "letsencrypt_email" {
  description = "Optional email for the Let's Encrypt account (expiry notices). Empty = no email"
  type        = string
  default     = ""
}

variable "letsencrypt_server" {
  description = "ACME server: production (trusted certs) or staging (for tests, untrusted certs, high rate limits)"
  type        = string
  default     = "https://acme-v02.api.letsencrypt.org/directory"
}

variable "argocd_subdomain" {
  description = "ArgoCD UI is published at <argocd_subdomain>.<domain>"
  type        = string
  default     = "argocd"
}

variable "versions" {
  description = "Helm chart versions of the platform components"
  type = object({
    aws_load_balancer_controller = optional(string, "3.6.0")
    cert_manager                 = optional(string, "v1.21.2")
    external_dns                 = optional(string, "1.23.0")
    istio                        = optional(string, "1.30.6")
    argo_cd                      = optional(string, "10.10.5")
  })
  default = {}
}
