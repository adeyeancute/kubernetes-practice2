module "eks" {
  source  = "terraform-aws-modules/eks/aws"
  version = "~> 21.29"

  name               = var.cluster_name
  kubernetes_version = var.kubernetes_version

  vpc_id     = module.vpc.vpc_id
  subnet_ids = module.vpc.private_subnets

  endpoint_public_access                   = true
  enable_cluster_creator_admin_permissions = true # the identity running terraform is cluster admin

  addons = {
    # pod networking, with NetworkPolicy enforcement turned on
    vpc-cni = {
      before_compute       = true
      configuration_values = jsonencode({ enableNetworkPolicy = "true" })
      pod_identity_association = [{
        role_arn        = module.vpc_cni_pod_identity.iam_role_arn
        service_account = "aws-node"
      }]
    }
    eks-pod-identity-agent = {
      before_compute = true
    }
    kube-proxy     = {}
    coredns        = {}
    metrics-server = {}
    aws-ebs-csi-driver = {
      pod_identity_association = [{
        role_arn        = module.ebs_csi_pod_identity.iam_role_arn
        service_account = "ebs-csi-controller-sa"
      }]
    }
    aws-efs-csi-driver = {
      # the controller creates/deletes access points; the node DaemonSet also calls the EFS API
      # to find the mount target IP when DNS is not ready yet (new file systems)
      pod_identity_association = [
        {
          role_arn        = module.efs_csi_pod_identity.iam_role_arn
          service_account = "efs-csi-controller-sa"
        },
        {
          role_arn        = module.efs_csi_pod_identity.iam_role_arn
          service_account = "efs-csi-node-sa"
        },
      ]
    }
  }

  # The EKS control plane calls Istio's webhooks (sidecar injection, config validation) on the
  # istiod pods, port 15017. The module only opens the common webhook ports by default: without
  # this rule every pod creation in an injected namespace fails with "failed calling webhook
  # object.sidecar-injector.istio.io ... context deadline exceeded".
  node_security_group_additional_rules = {
    istio_webhook = {
      description                   = "EKS control plane to istiod webhooks"
      protocol                      = "tcp"
      from_port                     = 15017
      to_port                       = 15017
      type                          = "ingress"
      source_cluster_security_group = true
    }
    # Pod-to-pod traffic between nodes on ALL ports. By default the module only allows node-to-node
    # traffic on 1025-65535: an app listening on port 80 (nginx, ...) is then only reachable from
    # pods on the SAME node, and requests through the ingress fail about half of the time.
    nodes_all_traffic = {
      description = "Node to node, all ports (pod to pod)"
      protocol    = "-1"
      from_port   = 0
      to_port     = 0
      type        = "ingress"
      self        = true
    }
  }

  eks_managed_node_groups = {
    default = {
      instance_types = var.node_instance_types
      ami_type       = "AL2023_x86_64_STANDARD"
      min_size       = var.node_min_size
      desired_size   = var.node_desired_size
      max_size       = var.node_max_size
    }
  }
}
