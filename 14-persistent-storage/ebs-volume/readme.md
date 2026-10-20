## Setting up dynamic provisioning in EKS cluster with EBS volumes

**Note:** The cluster used for this practice is the one created with `eksctl` in the `00-cluster-setup` folder (`my-cluster`, 3 nodes in 2 or more availability zones).

Prerequisites:
- AWS CLI installed and configured
- kubectl installed
- eksctl installed

```bash
export CLUSTER=my-cluster
export REGION=us-east-1
export ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
```

#### 1- Associate an IAM OIDC Provider with the Cluster

Already done if you created the cluster with `--with-oidc`. Running it again is harmless.
```bash
eksctl utils associate-iam-oidc-provider --region $REGION --cluster $CLUSTER --approve
```

#### 2- Create an IAM role for the EBS CSI Driver

The EBS CSI driver calls the AWS API to create, attach and delete EBS volumes, so it needs IAM permissions. AWS provides the managed policy **AmazonEBSCSIDriverPolicy**. `--role-only` creates just the IAM role (the EKS add-on creates the Kubernetes ServiceAccount itself).

```bash
eksctl create iamserviceaccount \
  --name ebs-csi-controller-sa \
  --namespace kube-system \
  --cluster $CLUSTER \
  --region $REGION \
  --role-name AmazonEKS_EBS_CSI_DriverRole_$CLUSTER \
  --role-only \
  --attach-policy-arn arn:aws:iam::aws:policy/service-role/AmazonEBSCSIDriverPolicy \
  --approve
```

#### 3- Install the Amazon EBS CSI Driver (EKS add-on)

The driver is available as an **EKS managed add-on**: AWS installs it, picks a version compatible with your cluster, and can upgrade it for you.
```bash
eksctl create addon --cluster $CLUSTER --region $REGION --name aws-ebs-csi-driver \
  --service-account-role-arn arn:aws:iam::$ACCOUNT_ID:role/AmazonEKS_EBS_CSI_DriverRole_$CLUSTER --force

# the add-on installs in the background: wait until it is ACTIVE (about 1 minute)
aws eks wait addon-active --cluster-name $CLUSTER --region $REGION --addon-name aws-ebs-csi-driver
aws eks describe-addon --cluster-name $CLUSTER --region $REGION --addon-name aws-ebs-csi-driver --query "addon.[addonVersion,status]" --output text
```

#### 4- Verify the EBS CSI Driver pods

- `ebs-csi-controller` (Deployment, 2 replicas): talks to the AWS API (create / attach / delete volumes).
- `ebs-csi-node` (DaemonSet, one per node): mounts the attached volume into the pods on that node.
```bash
kubectl get deployment ebs-csi-controller -n kube-system
kubectl get daemonset ebs-csi-node -n kube-system
```

#### 5- Verify Available Storage Classes

```bash
kubectl get storageclass
```
EKS creates the StorageClass **gp2** for you. We will deploy a PVC using it and a Pod that consumes that PVC.

### LAB: Using dynamic storage with EBS to deploy a pod with persistent storage

This lab demonstrates how to create a **PersistentVolumeClaim (PVC)** using EBS with the **gp2 StorageClass** in AWS EKS, and what **ReadWriteOnce** and **availability zones** mean in practice.

1. The manifest for the PVC and the pod is `ebs-pvc-pod.yaml`:

```yaml
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: ebs-pvc
spec:
  accessModes:
    - ReadWriteOnce  # Only one node can mount the volume
  resources:
    requests:
      storage: 5Gi  # Request 5GB of storage
  storageClassName: gp2  # StorageClass created by EKS
---
## Pod that will consume the PVC
apiVersion: v1
kind: Pod
metadata:
  name: pod-ebs
spec:
  containers:
  - name: app
    image: busybox:1.36
    command: [ "sh", "-c", "echo 'Hello from EBS!' > /data/test.txt && sleep 3600" ]
    volumeMounts:
    - mountPath: "/data"
      name: storage
  volumes:
  - name: storage
    persistentVolumeClaim:
      claimName: ebs-pvc
```
2. Apply it in the cluster

```bash
kubectl apply -f ebs-pvc-pod.yaml
```
Verify that the PVC status is **Bound** and that the pod is running and using the volume:
```bash
kubectl get pvc
kubectl get pv
kubectl get pod pod-ebs
# Git Bash on Windows: prefix with MSYS_NO_PATHCONV=1 (otherwise /data is rewritten to a Windows path)
kubectl exec -it pod-ebs -- cat /data/test.txt
```
In the AWS console (EC2 > Volumes) you can see the new 5 GiB volume, `In-use`, attached to one of your nodes.

3. Find where the volume lives: note the node of `pod-ebs`, and the zones of all nodes
```bash
kubectl get pod pod-ebs -o wide
kubectl get nodes -L topology.kubernetes.io/zone
# the PV remembers its zone: it can only be used by nodes in that zone
kubectl get pv -o jsonpath='{.items[0].spec.nodeAffinity.required.nodeSelectorTerms[0].matchExpressions}'; echo
```
Store the node names in variables (replace with your values):
```bash
NODE_SAME_ZONE=<another node, same zone as pod-ebs>
NODE_OTHER_ZONE=<a node in a different zone>
```
**Note:** if `pod-ebs` landed on the only node of its zone, there is no "same zone" node: skip step 4, or delete the PVC and the pod and apply `ebs-pvc-pod.yaml` again (the new volume follows the new pod).

4. **ReadWriteOnce:** run a second pod using the same PVC on **another node in the same zone** (`ebs-pvc-pod2.yaml`, uses `nodeName` to force the node)
```bash
sed "s/NODE_SAME_ZONE/$NODE_SAME_ZONE/" ebs-pvc-pod2.yaml | kubectl apply -f -
kubectl get pod pod-ebs2 -o wide
# STATUS stays ContainerCreating
kubectl describe pod pod-ebs2 | grep -A3 Events
# Warning FailedAttachVolume ... Volume is already used by pod(s) pod-ebs
```
The volume is attached to the first node, and an EBS volume can be attached to **one node at a time**. Now delete the first pod:
```bash
kubectl delete pod pod-ebs
kubectl get pod pod-ebs2 -w
# after about 30 to 60 seconds: Running (the volume was detached from node 1 and attached to node 2). CTRL+C
kubectl exec -it pod-ebs2 -- cat /data/test.txt
# Hello from EBS!
# Hello from pod-ebs2 (same zone)!
```
**The data survived**: it lives on the EBS volume, not in the pod.

5. **Availability zones:** run a pod using the same PVC on a node in **another zone** (`ebs-pvc-pod3.yaml`)
```bash
kubectl delete pod pod-ebs2
sed "s/NODE_OTHER_ZONE/$NODE_OTHER_ZONE/" ebs-pvc-pod3.yaml | kubectl apply -f -
kubectl get pod pod-ebs3 -o wide
# STATUS stays ContainerCreating, forever
kubectl describe pod pod-ebs3 | grep FailedAttachVolume | tail -1
# ... api error InvalidVolume.ZoneMismatch: The volume 'vol-...' is not in the same availability zone as instance 'i-...'
```
**Conclusion:**
- An EBS volume (**RWO**) can be used by one node at a time. It can move to another node when the pod that uses it goes away.
- An EBS volume lives in **one availability zone** and can never be attached to a node in another zone. Normally the scheduler knows that (it reads the PV zone) and places the pod in the right zone. Here we forced it with `nodeName`, which skips the scheduler.
- To share files between pods on many nodes and zones at the same time, use a **ReadWriteMany (RWX)** volume such as **Amazon EFS** (see the `efs-volume` folder).

6. **(Recommended) a gp3 StorageClass.** `gp3` volumes are about 20% cheaper than `gp2` with better baseline performance. `gp3-storageclass.yaml` creates a `gp3` class using the EBS CSI driver, encrypted, expandable, and makes it the **default** class (used by PVCs that do not set `storageClassName`). Lab 2 (WordPress) uses it.
```bash
kubectl apply -f gp3-storageclass.yaml
kubectl get storageclass
# gp3 (default)
```

#### Clean up

```bash
kubectl delete pod pod-ebs pod-ebs2 pod-ebs3 --ignore-not-found
kubectl delete pvc ebs-pvc
# the reclaim policy is Delete: the PV and the EBS volume are deleted with the PVC
kubectl get pv
```
Keep the EBS CSI add-on and the `gp3` StorageClass if you continue with the Labs. To remove the add-on at the very end:
```bash
eksctl delete addon --cluster $CLUSTER --region $REGION --name aws-ebs-csi-driver
eksctl delete iamserviceaccount --cluster $CLUSTER --region $REGION --namespace kube-system --name ebs-csi-controller-sa
```
