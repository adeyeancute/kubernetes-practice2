# EKS Add-ons: IRSA, Pod Identity, ALB Controller, EBS CSI, EFS CSI, Fargate

These are the AWS-side add-ons that turn a bare EKS cluster into a production-ready one. Every real EKS cluster has some subset of these. You should be able to explain what each one does and when you would install it.

This chapter shows the install commands, the manifests, and the AWS-side setup. You need an actual EKS cluster to run these (see chapter 00 for cluster setup).

## What is in this chapter

| Topic | File | What it teaches |
|---|---|---|
| IRSA (IAM Roles for Service Accounts) | `01-irsa-serviceaccount.yaml` | The older, widely-supported way to give a Pod AWS permissions. |
| Pod Identity | `02-pod-identity-association.sh` + `02-pod-identity-trust-policy.json` + `02-pod-identity-pod.yaml` | The current AWS-native way. Simpler than IRSA. |
| AWS Load Balancer Controller | `03-alb-controller-install.sh` + `04-ingress-alb.yaml` | Lets Ingress manifests create real AWS Application Load Balancers. |
| EBS CSI driver | `05-ebs-storageclass.yaml` + `06-ebs-pvc.yaml` | Dynamic block storage via PVCs. Single-AZ. |
| EFS CSI driver | `07-efs-storageclass.yaml` + `08-efs-pvc.yaml` | Shared NFS filesystem across AZs. Read-write from many Pods at once. |
| Fargate profile | `09-fargate-profile.sh` | Run Pods on serverless VMs. No node group to manage. |

## The mental model (read this first)

An EKS cluster has 3 layers of "how does this Pod get what it needs":

1. **How does the Pod get an IP?** VPC CNI gives every Pod a real VPC IP address. (Installed by default.)
2. **How does the Pod get AWS credentials?** IRSA or Pod Identity. Never hardcode access keys.
3. **How does traffic get to the Pod from outside?** Ingress + ALB Controller.
4. **How does the Pod persist data?** EBS CSI (fast local disk) or EFS CSI (shared).
5. **What runs the Pod?** Managed node group (EC2) or Fargate (serverless).

Everything in this chapter is one of those 5 questions.

## 1. IRSA (IAM Roles for Service Accounts)

IRSA lets a Kubernetes ServiceAccount assume an IAM role. When the Pod runs, the AWS SDK inside it automatically picks up temporary AWS credentials from that role. No secrets, no access keys.

How it works: the cluster has an **OIDC provider** registered in IAM. EKS injects a signed token into the Pod (`AWS_WEB_IDENTITY_TOKEN_FILE`) plus the role ARN (`AWS_ROLE_ARN`) from the ServiceAccount annotation `eks.amazonaws.com/role-arn`. The SDK exchanges the token for temporary credentials (`sts:AssumeRoleWithWebIdentity`).

Setup:

```bash
# 1. Enable OIDC provider on your cluster (one-time; already done with --with-oidc in chapter 00)
eksctl utils associate-iam-oidc-provider --cluster my-cluster --region us-east-1 --approve

# 2. Create the IAM role (trusting the OIDC provider + this ServiceAccount) AND the annotated ServiceAccount
eksctl create iamserviceaccount \
  --cluster my-cluster --region us-east-1 \
  --namespace default \
  --name s3-reader-sa \
  --attach-policy-arn arn:aws:iam::aws:policy/AmazonS3ReadOnlyAccess \
  --approve
kubectl get sa s3-reader-sa -o jsonpath='{.metadata.annotations}'; echo

# 3. Deploy a Pod using that ServiceAccount (the file only contains the Pod: see the comment inside)
kubectl apply -f 01-irsa-serviceaccount.yaml
kubectl wait --for=condition=Ready pod/s3-reader

# 4. Confirm the Pod has AWS creds
kubectl exec s3-reader -- aws sts get-caller-identity --query Arn --output text
# arn:aws:sts::<account>:assumed-role/eksctl-my-cluster-addon-iamserviceaccount-.../botocore-session-...
kubectl exec s3-reader -- aws s3 ls
kubectl exec s3-reader -- env | grep AWS_
```

## 2. Pod Identity (the current AWS-native approach)

Pod Identity replaces IRSA's OIDC setup with a native EKS API: an **association** "this ServiceAccount in this namespace uses this IAM role". No annotation on the ServiceAccount, no OIDC provider, and the IAM role trust policy is the same for every cluster (`02-pod-identity-trust-policy.json`, principal `pods.eks.amazonaws.com`). It needs the `eks-pod-identity-agent` add-on (a DaemonSet that hands out the credentials).

Setup:

```bash
# 1. IAM role trusted by pods.eks.amazonaws.com
aws iam create-role --role-name pod-s3-reader \
  --assume-role-policy-document file://02-pod-identity-trust-policy.json
aws iam attach-role-policy --role-name pod-s3-reader \
  --policy-arn arn:aws:iam::aws:policy/AmazonS3ReadOnlyAccess

# 2. Install the agent add-on (if missing), create the ServiceAccount and the association
./02-pod-identity-association.sh my-cluster default s3-reader-pi pod-s3-reader
aws eks list-pod-identity-associations --cluster-name my-cluster --output table

# 3. Deploy a Pod using that ServiceAccount and confirm AWS creds work
kubectl apply -f 02-pod-identity-pod.yaml
kubectl wait --for=condition=Ready pod/s3-reader-pi
kubectl exec s3-reader-pi -- aws sts get-caller-identity --query Arn --output text
# arn:aws:sts::<account>:assumed-role/pod-s3-reader/eks-my-cluster-s3-reader-...
kubectl exec s3-reader-pi -- env | grep AWS_CONTAINER
# AWS_CONTAINER_CREDENTIALS_FULL_URI=http://169.254.170.23/v1/credentials  <- the agent
```
**Use a different ServiceAccount than the IRSA one.** If a ServiceAccount has both an IRSA annotation and a Pod Identity association, the AWS SDK uses IRSA first, and you cannot tell which one works.

## 3. AWS Load Balancer Controller

Vanilla K8s Ingress does nothing on its own. The AWS Load Balancer Controller watches Ingress objects and provisions real AWS Application Load Balancers.

Install: you already did it in **chapter 07** (with ExternalDNS for the DNS records). On a new cluster, `03-alb-controller-install.sh` runs the same steps (pinned v3.6.0, IAM policy of the same version) and does nothing if the controller is already there:

```bash
bash 03-alb-controller-install.sh my-cluster <aws-account-id>
```

Chapter 07 routed by **host name** (`app1.afriqhome.com`, `app2.afriqhome.com`). `04-ingress-alb.yaml` routes by **path** on one host: `https://alb-demo.afriqhome.com/app1` and `/app2` (replace the domain with yours). It includes two small apps that answer on any path:

```bash
kubectl apply -f 04-ingress-alb.yaml
kubectl describe ingress alb-demo
# Look for ADDRESS: <ALB DNS name>. That is your real ALB.
kubectl logs -n external-dns deploy/external-dns | grep alb-demo   # wait for CREATE, then ~1 minute
curl https://alb-demo.afriqhome.com/app1      # hello from app1
curl https://alb-demo.afriqhome.com/app2      # hello from app2
curl -I https://alb-demo.afriqhome.com/nope   # 404: no rule matches
```
**Note:** the ALB forwards the **full path** to the backend: the app receives `/app1`, not `/`. A plain nginx would answer 404 to `/app1`. Real apps either serve under that prefix or you use host-based routing.

## 4. EBS CSI driver

EBS is single-AZ block storage. Fast. Perfect for a single-Pod database.

Install: done in **chapter 13** (EKS add-on + IAM role). **Do not** run `aws eks create-addon --addon-name aws-ebs-csi-driver` without `--service-account-role-arn`: the driver then has no AWS permissions and every PVC stays `Pending`.

Use:

```bash
kubectl apply -f 05-ebs-storageclass.yaml   # the StorageClass "gp3" (same as chapter 13)
kubectl apply -f 06-ebs-pvc.yaml            # PVC + a PostgreSQL Pod using it
kubectl get pvc postgres-data
kubectl wait --for=condition=Ready pod/postgres
kubectl exec postgres -- psql -U postgres -c "select version();"
```
`06-ebs-pvc.yaml` sets `PGDATA=/var/lib/postgresql/data/pgdata`: a new EBS volume contains a `lost+found` directory, and PostgreSQL refuses to initialize a non-empty directory (`initdb: error: directory ... exists but is not empty`). Use a sub-directory of the mount point for every database image (MySQL, PostgreSQL, MongoDB...).

Trade-off: the Pod is pinned to the AZ where the EBS volume lives. If the node dies and no replacement exists in that AZ, the Pod cannot restart until AWS provisions a new node there.

## 5. EFS CSI driver

EFS is a shared NFS filesystem. Slower than EBS. Perfect for shared uploads, ML model files, or WordPress-style read-heavy content across many replicas.

Install: done in **chapter 13** (file system, one mount target per AZ, security group on port 2049, EKS add-on + IAM role). Reuse that file system (`$EFS_ID`).

Use:

```bash
sed "s/fs-XXXXXXXX/$EFS_ID/" 07-efs-storageclass.yaml | kubectl apply -f -   # StorageClass "efs-shared"
kubectl apply -f 08-efs-pvc.yaml            # RWX PVC + 3 nginx replicas mounting it
kubectl rollout status deployment/uploads-frontend

# write from one Pod, read from all of them (Git Bash: export MSYS_NO_PATHCONV=1 first)
POD1=$(kubectl get pods -l app=uploads-frontend -o jsonpath='{.items[0].metadata.name}')
kubectl exec $POD1 -- sh -c 'echo shared-file > /usr/share/nginx/html/uploads/a.txt'
for p in $(kubectl get pods -l app=uploads-frontend -o name); do kubectl exec $p -- cat /usr/share/nginx/html/uploads/a.txt; done
```

## 6. Fargate

Fargate lets Pods run on AWS-managed micro-VMs. No node group. You pay per Pod-second.

When to use: short-lived batch jobs, CronJobs, isolated services where you want a hard VM boundary.

Trade-offs: cold start of 30 to 90 seconds, ~20-30% price premium vs reserved EC2, no DaemonSets, no HostPath volumes, no privileged containers, no EBS volumes.

Setup:

```bash
bash 09-fargate-profile.sh my-cluster team-batch
```

Every Pod created in the `team-batch` namespace now lands on Fargate (a profile can also select Pods by labels):
```bash
kubectl create namespace team-batch
kubectl run fargate-test -n team-batch --image=nginx:1.27
kubectl get pod fargate-test -n team-batch -o wide -w
# Pending for ~60s, then Running on a node named fargate-ip-...
kubectl get nodes
# one "fargate-ip-..." node per Fargate Pod
```

## Cleanup

```bash
kubectl delete pod s3-reader s3-reader-pi --ignore-not-found
eksctl delete iamserviceaccount --cluster my-cluster --region us-east-1 --namespace default --name s3-reader-sa
ASSOC=$(aws eks list-pod-identity-associations --cluster-name my-cluster --namespace default --service-account s3-reader-pi --query "associations[0].associationId" --output text)
aws eks delete-pod-identity-association --cluster-name my-cluster --association-id $ASSOC
kubectl delete sa s3-reader-pi --ignore-not-found
aws iam detach-role-policy --role-name pod-s3-reader --policy-arn arn:aws:iam::aws:policy/AmazonS3ReadOnlyAccess
aws iam delete-role --role-name pod-s3-reader

kubectl delete -f 04-ingress-alb.yaml --ignore-not-found     # deletes the ALB; ExternalDNS removes the record
kubectl delete -f 06-ebs-pvc.yaml --ignore-not-found         # PVC deleted => EBS volume deleted (reclaimPolicy Delete)
kubectl delete -f 08-efs-pvc.yaml --ignore-not-found
kubectl delete storageclass efs-shared --ignore-not-found

kubectl delete namespace team-batch --ignore-not-found
eksctl delete fargateprofile --cluster my-cluster --region us-east-1 --name fargate-team-batch --wait
```

## Docs

- IRSA: https://docs.aws.amazon.com/eks/latest/userguide/iam-roles-for-service-accounts.html
- Pod Identity: https://docs.aws.amazon.com/eks/latest/userguide/pod-identities.html
- ALB Controller: https://kubernetes-sigs.github.io/aws-load-balancer-controller/
- EBS CSI: https://docs.aws.amazon.com/eks/latest/userguide/ebs-csi.html
- EFS CSI: https://docs.aws.amazon.com/eks/latest/userguide/efs-csi.html
- Fargate: https://docs.aws.amazon.com/eks/latest/userguide/fargate.html
