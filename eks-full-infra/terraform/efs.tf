# Amazon EFS: shared (ReadWriteMany) storage for the pods. One file system for the whole cluster;
# every PersistentVolumeClaim of the "efs" StorageClass gets its own EFS access point (its own
# directory, owner and permissions), created and deleted by the EFS CSI driver.
#
# Network: one mount target per AZ in the private subnets (where the nodes are), reachable on
# NFS port 2049 from the nodes only.

resource "aws_security_group" "efs" {
  name        = "${var.cluster_name}-efs"
  description = "NFS from the EKS nodes to EFS"
  vpc_id      = module.vpc.vpc_id
}

resource "aws_vpc_security_group_ingress_rule" "efs_from_nodes" {
  security_group_id            = aws_security_group.efs.id
  description                  = "NFS from the EKS nodes"
  ip_protocol                  = "tcp"
  from_port                    = 2049
  to_port                      = 2049
  referenced_security_group_id = module.eks.node_security_group_id
}

resource "aws_efs_file_system" "this" {
  creation_token   = "${var.cluster_name}-efs"
  encrypted        = true
  performance_mode = "generalPurpose"
  throughput_mode  = "elastic" # pay for what you use, no provisioning

  lifecycle_policy {
    transition_to_ia = "AFTER_30_DAYS" # cold files move to the cheaper Infrequent Access class
  }

  tags = {
    Name = "${var.cluster_name}-efs"
  }
}

resource "aws_efs_mount_target" "this" {
  count           = length(module.vpc.private_subnets)
  file_system_id  = aws_efs_file_system.this.id
  subnet_id       = module.vpc.private_subnets[count.index]
  security_groups = [aws_security_group.efs.id]
}

module "efs_csi_pod_identity" {
  source  = "terraform-aws-modules/eks-pod-identity/aws"
  version = "~> 2.10"

  name                      = "${var.cluster_name}-efs-csi"
  attach_aws_efs_csi_policy = true
  # the associations are created by the aws-efs-csi-driver add-on (eks.tf)
}
