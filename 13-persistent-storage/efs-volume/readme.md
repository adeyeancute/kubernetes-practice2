## Setting up dynamic provisioning in EKS using Amazon EFS to deploy a simple application

**Amazon EFS** is a managed NFS file system. Unlike EBS, it is **ReadWriteMany (RWX)**: many pods, on many nodes, in **all** availability zones, can read and write the same files at the same time.

#### Prerequisites

- The EKS cluster `my-cluster` from chapter 00.
- **AWS CLI**, **kubectl** and **eksctl** installed.

```bash
export CLUSTER=my-cluster
export REGION=us-east-1
export ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
```

#### Step 1: Create the Filesystem
1. Get the VPC ID, its CIDR and the cluster security group (every node of the cluster has it)

```bash
VPC_ID=$(aws eks describe-cluster --name $CLUSTER --region $REGION --query "cluster.resourcesVpcConfig.vpcId" --output text)
CLUSTER_SG=$(aws eks describe-cluster --name $CLUSTER --region $REGION --query "cluster.resourcesVpcConfig.clusterSecurityGroupId" --output text)
echo $VPC_ID $CLUSTER_SG
```
2. Create a security group for EFS in the cluster VPC, and open the NFS port **2049** to the nodes

```bash
SG_ID=$(aws ec2 create-security-group --group-name "efs-$CLUSTER" --description "EFS for EKS $CLUSTER" --vpc-id $VPC_ID --query "GroupId" --output text --region $REGION)
aws ec2 authorize-security-group-ingress --group-id $SG_ID --protocol tcp --port 2049 --source-group $CLUSTER_SG --region $REGION
```

3. Create the (encrypted) EFS filesystem
```bash
EFS_ID=$(aws efs create-file-system --creation-token "efs-$CLUSTER" --encrypted --tags "Key=Name,Value=efs-$CLUSTER" --query "FileSystemId" --output text --region $REGION)
echo $EFS_ID
```
4. Create **one mount target per availability zone**. A mount target is the network endpoint (an IP in a subnet) that nodes of that AZ use to reach the file system. EFS allows only one mount target per AZ, and eksctl creates 2 subnets per AZ (public + private), so we use the private ones:
```bash
for subnet in $(aws ec2 describe-subnets --region $REGION --filters "Name=vpc-id,Values=$VPC_ID" "Name=map-public-ip-on-launch,Values=false" --query "Subnets[].SubnetId" --output text); do
  aws efs create-mount-target --file-system-id $EFS_ID --subnet-id $subnet --security-groups $SG_ID --region $REGION --query "[MountTargetId,AvailabilityZoneName]" --output text
done

# wait until every mount target is "available" (about 1 to 2 minutes)
aws efs describe-mount-targets --file-system-id $EFS_ID --region $REGION --query "MountTargets[].[AvailabilityZoneName,LifeCycleState]" --output table
```
**Note:** after a mount target becomes `available`, its DNS name needs about **1 to 2 more minutes** to resolve. Pods created before that stay in `ContainerCreating` for a while (`Failed to resolve "fs-....efs.us-east-1.amazonaws.com"`), then start on their own when the kubelet retries.

Now that the filesystem is created with the mount targets, let's install the EFS CSI driver.

#### Step 2: Create an IAM Role for the EFS CSI Driver
The EFS CSI driver creates an **access point** (a directory with its own owner and permissions) on the file system for every PVC, so it needs IAM permissions. AWS provides the managed policy **AmazonEFSCSIDriverPolicy**.

```bash
eksctl utils associate-iam-oidc-provider --cluster $CLUSTER --region $REGION --approve   # already done with --with-oidc

eksctl create iamserviceaccount \
  --name efs-csi-controller-sa \
  --namespace kube-system \
  --cluster $CLUSTER \
  --region $REGION \
  --role-name AmazonEKS_EFS_CSI_DriverRole_$CLUSTER \
  --role-only \
  --attach-policy-arn arn:aws:iam::aws:policy/service-role/AmazonEFSCSIDriverPolicy \
  --approve
```

#### Step 3: Install the Amazon EFS CSI Driver (EKS add-on)

```bash
eksctl create addon --cluster $CLUSTER --region $REGION --name aws-efs-csi-driver \
  --service-account-role-arn arn:aws:iam::$ACCOUNT_ID:role/AmazonEKS_EFS_CSI_DriverRole_$CLUSTER --force
aws eks wait addon-active --cluster-name $CLUSTER --region $REGION --addon-name aws-efs-csi-driver
```
Verify that the pods are running
```bash
kubectl get deployment efs-csi-controller -n kube-system
kubectl get daemonset efs-csi-node -n kube-system
```

#### Step 4: Create the storageClass for dynamic provisioning

The StorageClass (`efs-storage-class.yaml`) references your EFS file system:
```yaml
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: efs-sc
provisioner: efs.csi.aws.com
parameters:
  provisioningMode: efs-ap      # one EFS access point per PVC
  fileSystemId: your-efs-filesystem-id
  directoryPerms: "700"
```

Put your **FileSystemId** in it (on the fly with `sed`) and apply it:

```bash
sed "s/your-efs-filesystem-id/$EFS_ID/" efs-storage-class.yaml | kubectl apply -f -
kubectl get storageclass
```
#### Step 5: Create a PVC and a deployment 

The file `efs-pvc-deployment.yaml` creates the PVC, a Deployment with 3 replicas (spread over the nodes) that all mount it, and a Service:

```yaml
### pvc definition
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: efs-pvc
spec:
  accessModes:
    - ReadWriteMany  # RWX for many nodes
  resources:
    requests:
      storage: 5Gi  # size (EFS is elastic thus adjust automatically)
  storageClassName: efs-sc
---
### deployment def
apiVersion: apps/v1
kind: Deployment
metadata:
  name: my-app
spec:
  replicas: 3
  selector:
    matchLabels:
      app: my-app
  template:
    metadata:
      labels:
        app: my-app
    spec:
      containers:
      - name: app
        image: nginx:1.27
        volumeMounts:
        - name: efs-volume
          mountPath: /data
      volumes:
      - name: efs-volume
        persistentVolumeClaim:
          claimName: efs-pvc
---
### service def
apiVersion: v1
kind: Service
metadata:
  name: my-app-service
spec:
  type: ClusterIP
  selector:
    app: my-app
  ports:
    - port: 80
      targetPort: 80
```

Apply the file to the cluster and verify

```bash
kubectl apply -f efs-pvc-deployment.yaml
kubectl get pvc efs-pvc
# STATUS Bound, ACCESS MODES RWX
kubectl rollout status deployment/my-app
kubectl get pods -l app=my-app -o wide
# the 3 pods run on different nodes, in different availability zones
```
Check Shared Data Across all the Pods

```bash
# Git Bash on Windows: run "export MSYS_NO_PATHCONV=1" first (otherwise /data is rewritten to a Windows path)
# Write a file from the first pod...
POD1=$(kubectl get pods -l app=my-app -o jsonpath='{.items[0].metadata.name}')
kubectl exec $POD1 -- sh -c "echo 'Hello EFS' > /data/test.txt"

# ...and read it from every pod
for p in $(kubectl get pods -l app=my-app -o name); do echo "$p: $(kubectl exec $p -- cat /data/test.txt)"; done
```
All pods see the same file `test.txt`, even across availability zones, because they share the EFS volume. Compare with the EBS lab, where a second node could not even attach the volume.

## Cleanup (When Needed)
```bash
kubectl delete -f efs-pvc-deployment.yaml
kubectl delete storageclass efs-sc
# delete the mount targets, wait until they are gone, then the file system
for mt in $(aws efs describe-mount-targets --file-system-id $EFS_ID --region $REGION --query "MountTargets[].MountTargetId" --output text); do
  aws efs delete-mount-target --mount-target-id $mt --region $REGION
done
aws efs describe-mount-targets --file-system-id $EFS_ID --region $REGION --query "length(MountTargets)"   # repeat until 0
aws efs delete-file-system --file-system-id $EFS_ID --region $REGION
## delete the EFS security group (works once the mount targets are deleted)
aws ec2 delete-security-group --group-id $SG_ID --region $REGION
## remove the driver
eksctl delete addon --cluster $CLUSTER --region $REGION --name aws-efs-csi-driver
eksctl delete iamserviceaccount --cluster $CLUSTER --region $REGION --namespace kube-system --name efs-csi-controller-sa
```
**Note:** keep EFS if you plan to do Lab 2 (WordPress uses `efs-sc`).

Delete your cluster when done practicing.

## Notes For production:

- Add resource requests/limits
- Configure pod anti-affinity
- Enable EFS backup (AWS Backup)
- Restrict IAM permissions to specific EFS resources

This provides a shared, persistent filesystem accessible by all pods simultaneously.
