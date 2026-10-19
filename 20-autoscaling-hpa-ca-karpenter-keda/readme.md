# Kubernetes Autoscaling on EKS - HPA, VPA, Cluster Autoscaler, Karpenter, KEDA

Autoscaling in Kubernetes is **not one thing**. It is at least five tools that each solve a different problem. This chapter walks through them in the order you typically reach for them in production.

## 1. HPA (CPU-based reactive autoscaling)

The **Horizontal Pod Autoscaler (HPA)** adjusts the number of pod replicas in a Deployment, ReplicaSet, or StatefulSet based on CPU/memory usage or custom metrics.

- **Goal**: keep resource utilization around a target (e.g., 50% CPU).
- **Example**: if pods are under high CPU load, HPA adds more pods.

### Prerequisites

- An EKS cluster created with `eksctl`.
- `kubectl` configured to access your cluster.
- Metrics Server (already included with `eksctl`-based clusters).

```bash
kubectl top nodes
kubectl top pods
kubectl get deployment -n kube-system
```

You should see `metrics-server` available and ready (2/2).

### Deploy a sample app with HPA

Apply `nginx-deploy-hpa.yaml`. It contains a Deployment, a Service, and an HPA targeted at 20% CPU utilization.

```bash
kubectl apply -f nginx-deploy-hpa.yaml
kubectl get deploy
kubectl get svc
kubectl get hpa
kubectl get pods
```

- **target**: 20% average CPU utilization
- **min**: 1 pod
- **max**: 10 pods

**WARNING**: you may see `<unknown>/20%` for 1-2 minutes, then `0%/20%`.

### Generate load

Open another terminal and run a load generator:

```bash
kubectl run -i --tty load-generator --rm --image=busybox:1.36 --restart=Never -- sh
# inside the pod:
while true; do wget -q -O - http://nginx-service; done
```

In the first terminal:

```bash
kubectl get hpa -w
kubectl get pods
kubectl top pods
```

Stop the load generator (Ctrl-C) and watch HPA scale back down. It can take a few minutes.

---

## 2. VPA (Vertical Pod Autoscaler)

### What is VPA?

The **Vertical Pod Autoscaler** changes a pod's CPU/memory **requests** to right-size it, instead of changing the number of replicas. It solves the very common "I have no idea what to set for `resources.requests`" problem.

### A brief history

VPA was the second autoscaler created by SIG-Autoscaling (after HPA), starting around 2018. It lives in the same `kubernetes/autoscaler` repository as Cluster Autoscaler. It reached **v1.0 in 2024** and the current default at the time of this rewrite is **v1.7.0** (requires Kubernetes 1.28+). Until K8s 1.33, VPA could only resize pods by evicting and recreating them. K8s 1.33's `InPlacePodVerticalScaling` alpha lets VPA's new `InPlace` and `InPlaceOrRecreate` modes resize pods without restarting.

### Why it matters

Most teams pick `requests` / `limits` numbers out of thin air on day one and never revisit them. VPA reads actual usage and tells you the right values — either as a recommendation, or by applying them automatically.

### The actual update modes

`spec.updatePolicy.updateMode` accepts **six** values (verified against the upstream `types.go`):

| Mode | Behavior |
|---|---|
| `Off` | VPA only **reports recommendations**; never changes anything. Run in this mode for a week to gather data, then read `kubectl describe vpa <name>`. |
| `Initial` | Applies the recommendation only when a pod is first created; never afterwards. Safe. |
| `Recreate` | Evicts and recreates pods to resize them. This is the new default. |
| `Auto` | **Deprecated.** Currently equivalent to `Recreate`. Will be removed in a future API version. |
| `InPlaceOrRecreate` | Tries to resize in-place; falls back to recreate if not possible. Requires K8s 1.33+ with the `InPlacePodVerticalScaling` feature gate. |
| `InPlace` | Only resize in-place; never evict. Requires K8s 1.33+ and the VPA `InPlace` feature gate. |

> **Warning**: VPA in any mode that mutates resources can fight HPA if both target the same metric (CPU/memory). The standard advice is to use HPA for CPU/memory and VPA in `Off` mode for recommendations, or use VPA's resize modes only when HPA targets custom metrics.

### When to use vs not use it

- **Use it in `Off` mode for visibility** on every new workload. Almost free, almost no risk.
- **Use it in `Recreate` mode** for batch jobs, internal tooling, and steady workloads where eviction is tolerable.
- **Avoid it on workloads that already use HPA on CPU/memory** unless you scope VPA only to set the lower bound.

### Prerequisites

- EKS cluster (VPA 1.8 works on K8s 1.28+).
- `kubectl` and `helm` installed locally.
- Metrics Server installed in the cluster (already present on EKS).

### Install (official Helm chart)

The `kubernetes/autoscaler` project now publishes an official chart, `vertical-pod-autoscaler` (chart 0.14.0 = VPA 1.8.0):

```bash
helm repo add autoscaler https://kubernetes.github.io/autoscaler
helm repo update
helm install vpa autoscaler/vertical-pod-autoscaler -n kube-system --version 0.14.0 --wait
```
(The older method, the `hack/vpa-up.sh` script from a git clone of the repo, still works but needs `bash` and `openssl` and is painful on Windows.)

The chart installs three components into `kube-system` (2 replicas each):

- **recommender** — reads metrics, computes recommendations.
- **updater** — evicts pods that need to be resized.
- **admission-controller** — mutates pods at admission time so they come back with the new requests.

It also generates the TLS certificate used by the admission controller webhook.

### Verify

```bash
kubectl get pods -n kube-system | grep vpa
# expect: vpa-recommender, vpa-updater, vpa-admission-controller
kubectl get crds | grep verticalpodautoscaler
```

### Sample manifest (`vpa-example.yaml`)

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: hamster
spec:
  replicas: 2
  selector:
    matchLabels:
      app: hamster
  template:
    metadata:
      labels:
        app: hamster
    spec:
      containers:
      - name: hamster
        image: busybox:1.36
        resources:
          requests:
            cpu: 100m
            memory: 50Mi
        command: ["/bin/sh"]
        args:
        - "-c"
        - "while true; do timeout 0.5 yes >/dev/null; sleep 0.5; done"
---
apiVersion: autoscaling.k8s.io/v1
kind: VerticalPodAutoscaler
metadata:
  name: hamster-vpa
spec:
  targetRef:
    apiVersion: "apps/v1"
    kind:       Deployment
    name:       hamster
  updatePolicy:
    updateMode: "Off"          # recommend only. Change to "Recreate" to let VPA resize the pods
  resourcePolicy:
    containerPolicies:
      - containerName: '*'
        minAllowed:
          cpu: 50m
          memory: 32Mi
        maxAllowed:
          cpu: 1
          memory: 500Mi
        controlledResources: ["cpu", "memory"]
```
The `hamster` pods request **100m** CPU but each one burns about **0.5 CPU** (`yes` runs half of the time).

### Apply + verify

```bash
kubectl apply -f vpa-example.yaml
kubectl get vpa
kubectl describe vpa hamster-vpa
# look under "Recommendation:" for target / lowerBound / upperBound CPU & memory
```

It can take a few minutes for the recommender to produce values (`PROVIDED True`). Example result:
```
NAME          MODE   CPU    MEM     PROVIDED
hamster-vpa   Off    813m   250Mi   True
```
VPA says: "you asked for 100m, you actually need about 813m" (target), anything between `lowerBound` and `upperBound` is acceptable:
```bash
kubectl get vpa hamster-vpa -o jsonpath='{.status.recommendation.containerRecommendations[0]}'; echo
```
With `updateMode: "Off"` nothing changes: you copy the numbers into your manifests. With `"Recreate"`, the updater evicts the pods and the admission controller recreates them with the new requests.

### Cleanup

```bash
kubectl delete -f vpa-example.yaml
# tear down VPA itself (helm keeps the CRDs on purpose, delete them if you are done):
helm uninstall vpa -n kube-system
kubectl delete crd verticalpodautoscalers.autoscaling.k8s.io verticalpodautoscalercheckpoints.autoscaling.k8s.io
```

---

## 3. Cluster Autoscaler (node-level capacity, ASG-based)

### What is Cluster Autoscaler?

The **Kubernetes Cluster Autoscaler (CA)** scales the number of nodes in your cluster up and down. On AWS it does this by adjusting the desired capacity of EC2 Auto Scaling Groups (ASGs). It is the **older** of the two node-level autoscalers and is what AWS still documents alongside Karpenter today.

### A brief history

Cluster Autoscaler launched in 2016 in the `kubernetes/autoscaler` repository alongside HPA. For most of EKS's life it was *the* answer to "I need more nodes." It is solid, conservative, and works on every cloud — but it always reacts in terms of pre-defined ASGs, which can leave money on the table.

### Why it matters

If your cluster uses EKS managed node groups (or self-managed ASGs), CA is the simplest way to make the cluster scale itself.

### When to use vs not use it

- **Use CA** when you already have well-tuned node groups and want minimal moving parts.
- **Use Karpenter instead** for greenfield EKS clusters — see the next section.

### Prerequisites

- EKS cluster with one or more **managed node groups** (or self-managed ASGs).
- ASG tags `k8s.io/cluster-autoscaler/enabled=true` and `k8s.io/cluster-autoscaler/<cluster-name>=owned` on every ASG you want CA to control. **EKS managed node groups add them automatically** (the `my-nodes` group from chapter 00 has them). Check:
```bash
ASG=$(aws eks describe-nodegroup --cluster-name my-cluster --nodegroup-name my-nodes --query "nodegroup.resources.autoScalingGroups[0].name" --output text)
aws autoscaling describe-tags --filters "Name=auto-scaling-group,Values=$ASG" --query "Tags[?contains(Key,'cluster-autoscaler')].[Key,Value]" --output text
aws autoscaling describe-auto-scaling-groups --auto-scaling-group-names $ASG --query "AutoScalingGroups[0].[MinSize,DesiredCapacity,MaxSize]" --output text
# CA never goes above MaxSize (4 with the chapter 00 command)
```
- IAM OIDC provider associated with the cluster.
- `kubectl`, `eksctl`, `helm`.

### 1. Create the IAM policy

The upstream README publishes the JSON for the full features policy. Save the JSON below as `cluster-autoscaler-policy.json` (this is the **Full Cluster Autoscaler Features Policy (Recommended)** from the upstream `cluster-autoscaler/cloudprovider/aws/README.md`):

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": [
        "autoscaling:DescribeAutoScalingGroups",
        "autoscaling:DescribeAutoScalingInstances",
        "autoscaling:DescribeLaunchConfigurations",
        "autoscaling:DescribeScalingActivities",
        "ec2:DescribeImages",
        "ec2:DescribeInstanceTypes",
        "ec2:DescribeLaunchTemplateVersions",
        "ec2:GetInstanceTypesFromInstanceRequirements",
        "eks:DescribeNodegroup"
      ],
      "Resource": ["*"]
    },
    {
      "Effect": "Allow",
      "Action": [
        "autoscaling:SetDesiredCapacity",
        "autoscaling:TerminateInstanceInAutoScalingGroup"
      ],
      "Resource": ["*"]
    }
  ]
}
```

```bash
aws iam create-policy \
  --policy-name AmazonEKSClusterAutoscalerPolicy \
  --policy-document file://cluster-autoscaler-policy.json
```

### 2. Create the IRSA ServiceAccount

```bash
eksctl create iamserviceaccount \
  --cluster=my-cluster \
  --namespace=kube-system \
  --name=cluster-autoscaler \
  --attach-policy-arn=arn:aws:iam::<your-account-id>:policy/AmazonEKSClusterAutoscalerPolicy \
  --override-existing-serviceaccounts \
  --region=us-east-1 \
  --approve
```

### 3. Install via Helm

```bash
helm repo add autoscaler https://kubernetes.github.io/autoscaler
helm repo update

helm install cluster-autoscaler autoscaler/cluster-autoscaler --version 9.59.0 \
  --namespace kube-system \
  --set autoDiscovery.clusterName=my-cluster \
  --set awsRegion=us-east-1 \
  --set rbac.serviceAccount.create=false \
  --set rbac.serviceAccount.name=cluster-autoscaler \
  --set image.tag=v1.36.1 \
  --wait
```

> **Version pin**: the Cluster Autoscaler container image tag must match your Kubernetes minor version (CA `v1.36.x` for K8s 1.36). The chart default lags behind (chart 9.59.0 ships CA 1.35), so always set `--set image.tag=...`. Check the [autoscaler releases page](https://github.com/kubernetes/autoscaler/releases) for the exact patch version that matches your cluster.

### 4. Verify

```bash
kubectl get pods -n kube-system -l app.kubernetes.io/name=aws-cluster-autoscaler
kubectl logs -n kube-system deploy/cluster-autoscaler-aws-cluster-autoscaler --tail=50
```

### 5. Test

Apply a deployment whose pods do not fit on the current nodes (10 pods x 500m CPU = 5 CPU, more than 3 t3.medium can give after the system pods):

```bash
kubectl create deployment overflow --image=nginx:1.27 --replicas=10
kubectl set resources deployment overflow --requests=cpu=500m
kubectl get pods -l app=overflow --field-selector=status.phase=Pending   # some pods are Pending
# CA detects the Pending pods and grows the ASG
kubectl logs -n kube-system deploy/cluster-autoscaler-aws-cluster-autoscaler | grep "scale-up plan"
# Final scale-up plan: [{eks-my-nodes-... 3->4 (max: 4)}]
kubectl get nodes -w     # a 4th node joins after about 1 minute
```
If some pods are still Pending with 4 nodes: that is the `MaxSize` of the node group.

Then delete the deployment and CA will scale the ASG back down (default: after ~10 minutes of underutilization).

### 6. Cleanup

```bash
kubectl delete deployment overflow
helm uninstall cluster-autoscaler -n kube-system
eksctl delete iamserviceaccount --cluster=my-cluster --name=cluster-autoscaler --namespace=kube-system --region=us-east-1
aws iam delete-policy --policy-arn arn:aws:iam::<your-account-id>:policy/AmazonEKSClusterAutoscalerPolicy
```

---

## 4. Karpenter (node-level capacity, instance-by-instance)

### What is Karpenter?

**Karpenter** is AWS's open-source Kubernetes node autoscaler. Instead of scaling ASGs, it provisions individual EC2 instances sized to fit the actually-pending pods. It consolidates underused nodes automatically.

### A brief history

Karpenter was announced by AWS at re:Invent 2021 and became GA in 2022. It joined the CNCF as a Sandbox project in 2023, donated to SIG-Autoscaling. The provider-agnostic core lives at `kubernetes-sigs/karpenter`; the AWS implementation at `aws/karpenter-provider-aws`. The current release at the time of this rewrite is **v1.13.0**, supported on K8s 1.36 in the official getting-started guide.

### Why it matters

Karpenter looks at *all* the pending pods, computes the cheapest set of instance types that will fit them, launches those instances directly via EC2 RunInstances, and joins them to the cluster. It then continuously bin-packs and consolidates — terminating underused nodes and replacing them with smaller cheaper ones.

Net effect vs CA: **faster scale-up, much better bin-packing, lower spend** — at the cost of one more controller you have to operate.

### When to use vs not use it

- **Karpenter** is the default for new EKS clusters in 2026. AWS's official autoscaling guide leads with it.
- **Cluster Autoscaler** is fine for an existing cluster with well-tuned ASGs that you do not want to disturb.
- **EKS Auto Mode** is AWS's fully managed take on Karpenter — even less to operate, but less flexibility. Worth a look if you do not need custom NodePools.

### Prerequisites

The official getting-started guide expects these tools:

- AWS CLI configured (`aws sts get-caller-identity` works)
- `kubectl`
- `eksctl` (>= v0.202.0)
- `helm`

Set environment variables (values from the upstream guide):

```bash
export KARPENTER_NAMESPACE="kube-system"
export KARPENTER_VERSION="1.15.0"
export K8S_VERSION="1.36"
export AWS_PARTITION="aws"
export CLUSTER_NAME="karpenter-demo"
export AWS_DEFAULT_REGION="us-east-1"
export AWS_ACCOUNT_ID="$(aws sts get-caller-identity --query Account --output text)"
export TEMPOUT="$(mktemp)"
```

### 1. Create the supporting AWS infrastructure (CloudFormation)

**Note:** Karpenter replaces the Cluster Autoscaler: do not run both on the same cluster. This section creates a **second cluster**, `karpenter-demo` (2 x m5.large). Delete it at the end (step 7).

The upstream guide ships a CloudFormation template that creates the Karpenter controller IAM role, node IAM role, instance profile, SQS interruption queue, and EventBridge rules:

```bash
curl -fsSL "https://raw.githubusercontent.com/aws/karpenter-provider-aws/v${KARPENTER_VERSION}/website/content/en/preview/getting-started/getting-started-with-karpenter/cloudformation.yaml" > "${TEMPOUT}"

aws cloudformation deploy \
  --stack-name "Karpenter-${CLUSTER_NAME}" \
  --template-file "${TEMPOUT}" \
  --capabilities CAPABILITY_NAMED_IAM \
  --parameter-overrides "ClusterName=${CLUSTER_NAME}"
```

### 2. Create the EKS cluster wired up to Karpenter

Use `eksctl` with the upstream ClusterConfig (managed node group flavor). This creates the cluster, the OIDC provider, the IRSA Pod Identity association for the Karpenter ServiceAccount, and wires the Karpenter node role into the cluster's auth mapping:

```bash
eksctl create cluster -f - <<EOF
apiVersion: eksctl.io/v1alpha5
kind: ClusterConfig
metadata:
  name: ${CLUSTER_NAME}
  region: ${AWS_DEFAULT_REGION}
  version: "${K8S_VERSION}"
  tags:
    karpenter.sh/discovery: ${CLUSTER_NAME}

iam:
  withOIDC: true
  podIdentityAssociations:
  - namespace: "${KARPENTER_NAMESPACE}"
    serviceAccountName: karpenter
    roleName: ${CLUSTER_NAME}-karpenter
    permissionPolicyARNs:
    - arn:${AWS_PARTITION}:iam::${AWS_ACCOUNT_ID}:policy/KarpenterControllerNodeLifecyclePolicy-${CLUSTER_NAME}
    - arn:${AWS_PARTITION}:iam::${AWS_ACCOUNT_ID}:policy/KarpenterControllerIAMIntegrationPolicy-${CLUSTER_NAME}
    - arn:${AWS_PARTITION}:iam::${AWS_ACCOUNT_ID}:policy/KarpenterControllerEKSIntegrationPolicy-${CLUSTER_NAME}
    - arn:${AWS_PARTITION}:iam::${AWS_ACCOUNT_ID}:policy/KarpenterControllerInterruptionPolicy-${CLUSTER_NAME}
    - arn:${AWS_PARTITION}:iam::${AWS_ACCOUNT_ID}:policy/KarpenterControllerResourceDiscoveryPolicy-${CLUSTER_NAME}
    - arn:${AWS_PARTITION}:iam::${AWS_ACCOUNT_ID}:policy/KarpenterControllerZonalShiftPolicy-${CLUSTER_NAME}

iamIdentityMappings:
- arn: "arn:${AWS_PARTITION}:iam::${AWS_ACCOUNT_ID}:role/KarpenterNodeRole-${CLUSTER_NAME}"
  username: system:node:{{EC2PrivateDNSName}}
  groups:
  - system:bootstrappers
  - system:nodes

managedNodeGroups:
- instanceType: m5.large
  amiFamily: AmazonLinux2023
  name: ${CLUSTER_NAME}-ng
  desiredCapacity: 2
  minSize: 1
  maxSize: 10

addons:
- name: eks-pod-identity-agent
EOF
```

**If `eksctl create cluster` stops with a timeout** (laptop asleep, Wi-Fi lost) but CloudFormation shows every stack `CREATE_COMPLETE`, eksctl skipped its last steps. Add them by hand, then continue:
```bash
aws eks update-kubeconfig --name ${CLUSTER_NAME} --region ${AWS_DEFAULT_REGION}
P="arn:${AWS_PARTITION}:iam::${AWS_ACCOUNT_ID}:policy"
eksctl create podidentityassociation --cluster ${CLUSTER_NAME} --namespace ${KARPENTER_NAMESPACE} \
  --service-account-name karpenter --role-name ${CLUSTER_NAME}-karpenter \
  --permission-policy-arns "$P/KarpenterControllerNodeLifecyclePolicy-${CLUSTER_NAME},$P/KarpenterControllerIAMIntegrationPolicy-${CLUSTER_NAME},$P/KarpenterControllerEKSIntegrationPolicy-${CLUSTER_NAME},$P/KarpenterControllerInterruptionPolicy-${CLUSTER_NAME},$P/KarpenterControllerResourceDiscoveryPolicy-${CLUSTER_NAME},$P/KarpenterControllerZonalShiftPolicy-${CLUSTER_NAME}"
eksctl create iamidentitymapping --cluster ${CLUSTER_NAME} --arn "arn:${AWS_PARTITION}:iam::${AWS_ACCOUNT_ID}:role/KarpenterNodeRole-${CLUSTER_NAME}" \
  --username 'system:node:{{EC2PrivateDNSName}}' --group system:bootstrappers --group system:nodes
```

Create the EC2 Spot service-linked role (idempotent — ignore the "already exists" error):

```bash
aws iam create-service-linked-role --aws-service-name spot.amazonaws.com || true
```

### 3. Install Karpenter via Helm (from public ECR)

```bash
helm registry logout public.ecr.aws

helm upgrade --install karpenter oci://public.ecr.aws/karpenter/karpenter \
  --version "${KARPENTER_VERSION}" \
  --namespace "${KARPENTER_NAMESPACE}" --create-namespace \
  --set "settings.clusterName=${CLUSTER_NAME}" \
  --set "settings.interruptionQueue=${CLUSTER_NAME}" \
  --set controller.resources.requests.cpu=1 \
  --set controller.resources.requests.memory=1Gi \
  --set controller.resources.limits.cpu=1 \
  --set controller.resources.limits.memory=1Gi \
  --wait
```

### 4. Verify

```bash
kubectl get pods -n kube-system -l app.kubernetes.io/name=karpenter
kubectl get crds | grep karpenter
# expect: nodepools.karpenter.sh, nodeclaims.karpenter.sh, nodeoverlays.karpenter.sh, ec2nodeclasses.karpenter.k8s.aws
```

### 5. Sample NodePool + EC2NodeClass (`karpenter-nodepool.yaml`)

This NodePool says "give me AMD64 Linux nodes, **on-demand or Spot**, from generation 3+ of the c/m/r instance families; remove or replace under-used nodes 30 seconds after they become empty or under-utilized; replace every node after 30 days". When Spot is allowed, Karpenter picks the cheapest option that fits, so you usually get **Spot** instances:

```yaml
apiVersion: karpenter.sh/v1
kind: NodePool
metadata:
  name: default
spec:
  template:
    spec:
      nodeClassRef:
        group: karpenter.k8s.aws
        kind: EC2NodeClass
        name: default
      requirements:
        - key: kubernetes.io/arch
          operator: In
          values: ["amd64"]
        - key: kubernetes.io/os
          operator: In
          values: ["linux"]
        - key: karpenter.sh/capacity-type
          operator: In
          values: ["on-demand", "spot"]   # on-demand + spot mix
        - key: karpenter.k8s.aws/instance-category
          operator: In
          values: ["c", "m", "r"]
        - key: karpenter.k8s.aws/instance-generation
          operator: Gt
          values: ["2"]
      expireAfter: 720h   # 30 days - replace nodes regularly to pick up AMI updates
  limits:
    cpu: 1000
    memory: 1000Gi
  disruption:
    consolidationPolicy: WhenEmptyOrUnderutilized
    consolidateAfter: 30s
---
apiVersion: karpenter.k8s.aws/v1
kind: EC2NodeClass
metadata:
  name: default
spec:
  amiFamily: AL2023
  role: KarpenterNodeRole-${CLUSTER_NAME}
  subnetSelectorTerms:
    - tags:
        karpenter.sh/discovery: ${CLUSTER_NAME}
  securityGroupSelectorTerms:
    - tags:
        karpenter.sh/discovery: ${CLUSTER_NAME}
  amiSelectorTerms:
    - alias: al2023@latest
```

Apply it (using `envsubst` to fill `${CLUSTER_NAME}`):

```bash
envsubst '${CLUSTER_NAME}' < karpenter-nodepool.yaml | kubectl apply -f -
kubectl get nodepool
kubectl get ec2nodeclass
# both READY True. If False: kubectl describe ec2nodeclass default (SubnetsNotFound = wrong cluster name in the tags)
```

### 6. Test (the canonical "inflate" deployment)

```bash
kubectl create deployment inflate --image=public.ecr.aws/eks-distro/kubernetes/pause:3.7
kubectl set resources deployment inflate --requests=cpu=1
kubectl scale deployment inflate --replicas=5

# watch Karpenter provision instances:
kubectl logs -f -n "${KARPENTER_NAMESPACE}" -l app.kubernetes.io/name=karpenter -c controller
# "found provisionable pod(s)" -> "computed new nodeclaim(s) to fit pod(s)" -> "launched nodeclaim"
kubectl get nodeclaims
# NAME            TYPE         CAPACITY   ZONE         NODE                 READY
# default-hp76p   c5.2xlarge   spot       us-east-1a   ip-192-168-65-114    True
kubectl get nodes -w
```
In under a minute, Karpenter launched **one** instance sized for the 5 pending pods (5 CPU), as Spot. The Cluster Autoscaler can only add more copies of the node group instance type.

Then scale back down and watch consolidation:

```bash
kubectl delete deployment inflate
kubectl get nodeclaims -w           # Karpenter removes the empty node after about 1 to 2 minutes
# logs: "disrupting node(s)" -> "tainted node" -> "deleted node"
```

### 7. Cleanup

```bash
kubectl delete deployment inflate --ignore-not-found
kubectl delete nodepool default          # Karpenter terminates the nodes it created
kubectl delete ec2nodeclass default
kubectl get nodeclaims                   # wait until empty
helm uninstall karpenter --namespace "${KARPENTER_NAMESPACE}"
eksctl delete cluster --name "${CLUSTER_NAME}" --region "${AWS_DEFAULT_REGION}"
aws cloudformation delete-stack --stack-name "Karpenter-${CLUSTER_NAME}"   # after the cluster is gone
```

---

## 5. KEDA (event-driven, scale to zero)

### What is KEDA?

**KEDA** (Kubernetes Event-Driven Autoscaling) is a controller that watches an external source — queue depth, Kafka lag, RabbitMQ messages, Prometheus query, AWS SQS, cron expression, etc. — and scales a Deployment **0..N** based on it. Unlike HPA, KEDA can scale to **zero**.

### A brief history

KEDA started as a Microsoft / Red Hat collaboration in 2019 to fill HPA's biggest gap: scale-to-zero for event-driven workloads. It was donated to the CNCF in 2020 and **graduated** in 2023. The current release at the time of this rewrite is **v2.20.0**, requiring Kubernetes **1.30+**.

### Why it matters

HPA's minimum is 1 replica. For queue consumers, batch workers, and "wake up when there is work" services, you want **zero pods when idle**. KEDA hides itself behind a regular HPA: the `ScaledObject` you create generates an HPA on the fly when there is work, and removes it when the queue drains.

### Common 2026 use cases

- **SQS** consumers that should idle at 0 pods when the queue is empty.
- **Kafka** consumers that scale on consumer-group lag.
- **RabbitMQ** workers.
- Scheduled scale-up (warm a service before a known traffic spike).

### When to use vs not use it

- **Use KEDA** for any worker driven by an external queue / event source.
- **Stick with plain HPA** for HTTP services driven by CPU, memory, or a metric the in-cluster Prometheus already exposes.

### Prerequisites

- EKS cluster on K8s 1.30+.
- `kubectl`, `helm`.
- IAM OIDC provider associated with the cluster (for the IRSA pattern below).
- For the SQS demo: an SQS queue you control + the ARN of an IAM role allowing `sqs:GetQueueAttributes` and `sqs:GetQueueUrl` on that queue.

### 1. Install via Helm (the upstream recommended path)

```bash
helm repo add kedacore https://kedacore.github.io/charts
helm repo update

helm install keda kedacore/keda --version 2.21.0 \
  --namespace keda --create-namespace --wait
```

### 2. Verify

```bash
kubectl get pods -n keda
# expect: keda-operator, keda-operator-metrics-apiserver, keda-admission-webhooks
kubectl get crds | grep keda.sh
# expect: scaledobjects.keda.sh, scaledjobs.keda.sh, triggerauthentications.keda.sh, ...
```

### 3. IRSA for KEDA on EKS

Two different things need to read the queue, so two identities:
- the **KEDA operator** asks "how many messages are waiting?" (`sqs:GetQueueAttributes`) to decide the number of pods. It gets an IRSA role, and the `TriggerAuthentication` with `podIdentity.provider: aws` tells KEDA to use it.
- the **worker pods** receive and delete the messages. They run as the `worker-sa` ServiceAccount, with their own IRSA role.

(KEDA can also borrow the worker's role with `identityOwner: workload`, but then the operator must be allowed to `sts:AssumeRole` into it: more IAM plumbing. Keep it simple.)

Create the SQS queue and the IAM policy (`keda-sqs-read.json`, replace `<your-account-id>`):
```bash
export AWS_ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
aws sqs create-queue --queue-name my-queue --region us-east-1
```

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": [
        "sqs:GetQueueAttributes",
        "sqs:GetQueueUrl",
        "sqs:ReceiveMessage",
        "sqs:DeleteMessage"
      ],
      "Resource": "arn:aws:sqs:us-east-1:<your-account-id>:my-queue"
    }
  ]
}
```

```bash
aws iam create-policy \
  --policy-name KedaSqsReadPolicy \
  --policy-document file://keda-sqs-read.json

# the workers' identity
eksctl create iamserviceaccount \
  --cluster=my-cluster \
  --namespace=default \
  --name=worker-sa \
  --attach-policy-arn=arn:aws:iam::$AWS_ACCOUNT_ID:policy/KedaSqsReadPolicy \
  --override-existing-serviceaccounts \
  --region=us-east-1 \
  --approve

# the KEDA operator's identity (role only: the Helm chart owns the keda-operator ServiceAccount)
eksctl create iamserviceaccount \
  --cluster=my-cluster \
  --namespace=keda \
  --name=keda-operator \
  --role-name keda-operator-my-cluster \
  --role-only \
  --attach-policy-arn=arn:aws:iam::$AWS_ACCOUNT_ID:policy/KedaSqsReadPolicy \
  --region=us-east-1 \
  --approve
helm upgrade keda kedacore/keda -n keda --version 2.21.0 --reuse-values \
  --set podIdentity.aws.irsa.enabled=true \
  --set podIdentity.aws.irsa.roleArn=arn:aws:iam::$AWS_ACCOUNT_ID:role/keda-operator-my-cluster --wait
kubectl rollout restart deploy/keda-operator -n keda     # IRSA credentials are injected at pod creation
```

### 4. Sample manifest (`keda-scaledobject.yaml`)

The file contains the worker Deployment (starts at **0** replicas), the `TriggerAuthentication` and the `ScaledObject`. The worker loop receives one message, "processes" it for 2 seconds, then **deletes** it (a received message that is not deleted comes back after the visibility timeout):

```yaml
  triggers:
  - type: aws-sqs-queue
    authenticationRef:
      name: keda-aws-sqs-auth
    metadata:
      queueURL: "https://sqs.us-east-1.amazonaws.com/${AWS_ACCOUNT_ID}/my-queue"
      queueLength: "5"              # target: 5 messages per pod
      awsRegion: "us-east-1"
```

### 5. Apply + verify

```bash
# name the variable: a plain "envsubst" would also empty $QUEUE_URL and $RH inside the worker script
envsubst '${AWS_ACCOUNT_ID}' < keda-scaledobject.yaml | kubectl apply -f -
kubectl get scaledobject           # READY True (False + "AccessDenied" in the operator logs = IRSA problem)
kubectl describe scaledobject sqs-worker-scaledobject
kubectl get hpa                     # KEDA auto-creates an HPA named keda-hpa-<name>
kubectl get deploy sqs-worker       # should show 0 replicas while queue is empty
```

### 6. Test

Push some messages to your SQS queue and watch the Deployment scale up:

```bash
QUEUE_URL=https://sqs.us-east-1.amazonaws.com/$AWS_ACCOUNT_ID/my-queue
for i in $(seq 1 50); do
  aws sqs send-message --queue-url $QUEUE_URL --message-body "msg-$i" --region us-east-1 >/dev/null
done

kubectl get deploy sqs-worker -w
```
What you should see (50 messages, 5 per pod, max 10):
```
replicas=1  queue=50
replicas=4  queue=45
replicas=8  queue=28
replicas=10 queue=0     # the workers emptied the queue
replicas=0  queue=0     # 60 seconds later (cooldownPeriod): scaled to ZERO
```
Watch the queue at the same time: `aws sqs get-queue-attributes --queue-url $QUEUE_URL --attribute-names ApproximateNumberOfMessages`.

### 7. Cleanup

```bash
envsubst '${AWS_ACCOUNT_ID}' < keda-scaledobject.yaml | kubectl delete -f -
eksctl delete iamserviceaccount --cluster=my-cluster --name=worker-sa --namespace=default --region=us-east-1
eksctl delete iamserviceaccount --cluster=my-cluster --name=keda-operator --namespace=keda --region=us-east-1
aws sqs delete-queue --queue-url https://sqs.us-east-1.amazonaws.com/$AWS_ACCOUNT_ID/my-queue
aws iam delete-policy --policy-arn arn:aws:iam::$AWS_ACCOUNT_ID:policy/KedaSqsReadPolicy
helm uninstall keda -n keda
kubectl delete namespace keda
```

---

## 6. Decision matrix

| Symptom | Reach for |
|---|---|
| Steady traffic that ebbs and flows with the day | **HPA** (CPU or memory) |
| "I have no idea what to set for requests/limits" | **VPA** (start in `Off` mode, read recommendations) |
| Pods stuck in `Pending` because no node has room — existing ASG-based cluster | **Cluster Autoscaler** |
| Pods stuck in `Pending` — new EKS cluster | **Karpenter** |
| A queue / event-driven worker that should idle at 0 | **KEDA** |
| HTTP service driven by a custom metric (e.g., req/s) | **HPA** with an external/custom metric adapter |

Rule of thumb: **HPA + Karpenter** is the default pair for a new EKS workload in 2026. Add VPA in `Off` mode for visibility. Add KEDA when you have queue-driven services.

## Cleanup (all sections)

```bash
# HPA + nginx demo
kubectl delete -f nginx-deploy-hpa.yaml

# VPA demo (only if VPA controller is installed)
kubectl delete -f vpa-example.yaml --ignore-not-found

# Cluster Autoscaler (only if installed)
helm uninstall cluster-autoscaler -n kube-system 2>/dev/null || true

# Karpenter NodePool (only if Karpenter is installed)
kubectl delete -f karpenter-nodepool.yaml --ignore-not-found

# KEDA ScaledObject (only if KEDA is installed)
kubectl delete -f keda-scaledobject.yaml --ignore-not-found

# Optional: load-generator pod if still hanging around
kubectl delete pod load-generator --ignore-not-found
```
