**Note:** This lab should be done in the **EKS cluster**
# The ingress resource
Ingress exposes HTTP and HTTPS routes from outside the cluster to services within the cluster. Traffic routing is controlled by rules defined on the Ingress resource.

To use the ingress resource, you must configure an ingress controller such as ingress-nginx, HAproxy, AWS Load balancer

## Why Use Ingress?
- Reduces Cost – Uses a single entry point instead of multiple LoadBalancers.
- Supports Routing – Directs traffic based on URL paths or hostnames.
- Enables HTTPS (SSL) – Provides security for web applications.
- Load Balancing – Distributes traffic across multiple services.

## How Ingress Works
1. User sends a request to myapp.com/api.
2. Request reaches Ingress (single entry point).
3. Ingress checks rules and routes traffic.
4. Request is sent to the correct service inside the cluster.
5. The response is sent back to the user.

## Practice

### Prerequisites
- **Cluster:** the EKS cluster `my-cluster` from chapter 00 (created with `--with-oidc`).
- **Domain:** a public hosted zone in Route 53 (this course uses `afriqhome.com`; replace it everywhere with yours).
- **ACM Certificate:** an **issued** wildcard certificate for your domain (`*.afriqhome.com`) in the same region as the cluster. A wildcard covers one level only: `app1.afriqhome.com` is covered, `app1.k8s.afriqhome.com` is not.
```bash
aws acm list-certificates --region us-east-1 --query "CertificateSummaryList[].[DomainName,Status,CertificateArn]" --output table
```
- `kubectl`, `helm`, `eksctl` and the AWS CLI installed.

Set a few variables used by the commands below:
```bash
export CLUSTER=my-cluster
export REGION=us-east-1
export ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
export VPC_ID=$(aws eks describe-cluster --name $CLUSTER --region $REGION --query cluster.resourcesVpcConfig.vpcId --output text)
```

### Install the AWS Load Balancer Controller

The controller watches Ingress (and Gateway API) objects and creates real AWS load balancers (ALB / NLB) for them.

1. Make sure the IAM OIDC provider exists (already done if you created the cluster with `--with-oidc`):
```bash
eksctl utils associate-iam-oidc-provider --region $REGION --cluster $CLUSTER --approve
```

2. Create the IAM policy for the controller. Always use the policy from the **same version** as the controller you install (here v3.6.0):
```bash
curl -o iam_policy.json https://raw.githubusercontent.com/kubernetes-sigs/aws-load-balancer-controller/v3.6.0/docs/install/iam_policy.json
aws iam create-policy --policy-name AWSLoadBalancerControllerIAMPolicy --policy-document file://iam_policy.json
```
If you get `EntityAlreadyExists` (the policy is left over from a previous class), update it to the new version instead:
```bash
aws iam create-policy-version --policy-arn arn:aws:iam::$ACCOUNT_ID:policy/AWSLoadBalancerControllerIAMPolicy \
  --policy-document file://iam_policy.json --set-as-default
# if this fails with LimitExceeded (max 5 versions), delete the oldest one first:
# aws iam list-policy-versions --policy-arn arn:aws:iam::$ACCOUNT_ID:policy/AWSLoadBalancerControllerIAMPolicy
# aws iam delete-policy-version --policy-arn arn:aws:iam::$ACCOUNT_ID:policy/AWSLoadBalancerControllerIAMPolicy --version-id v1
```

3. Create an IAM role + Kubernetes ServiceAccount for the controller (IRSA, see chapter 24):
```bash
eksctl create iamserviceaccount --cluster=$CLUSTER --region $REGION --namespace=kube-system \
  --name=aws-load-balancer-controller \
  --attach-policy-arn=arn:aws:iam::$ACCOUNT_ID:policy/AWSLoadBalancerControllerIAMPolicy \
  --override-existing-serviceaccounts --approve
```

4. Install the Gateway API CRDs (used in the second half of this chapter, and by Istio in chapter 25). The controller detects them at startup, so install them **before** the controller:
```bash
kubectl apply --server-side -f https://github.com/kubernetes-sigs/gateway-api/releases/download/v1.6.0/standard-install.yaml
kubectl apply -f https://raw.githubusercontent.com/kubernetes-sigs/aws-load-balancer-controller/refs/heads/main/config/crd/gateway/gateway-crds.yaml
```

5. Install the controller with Helm:
```bash
helm repo add eks https://aws.github.io/eks-charts
helm repo update
helm install aws-load-balancer-controller eks/aws-load-balancer-controller -n kube-system --version 3.6.0 \
  --set clusterName=$CLUSTER \
  --set region=$REGION \
  --set vpcId=$VPC_ID \
  --set serviceAccount.create=false \
  --set serviceAccount.name=aws-load-balancer-controller \
  --set enableServiceMutatorWebhook=false
kubectl rollout status deploy/aws-load-balancer-controller -n kube-system
```
**Why `enableServiceMutatorWebhook=false`?** Without it, the controller takes over **every** `Service` of type `LoadBalancer` and creates an **internal** NLB for it (not reachable from the internet). With it, plain `type: LoadBalancer` services keep working as in chapter 06, and the controller only handles Ingress, Gateway API and services that explicitly ask for it (annotation `service.beta.kubernetes.io/aws-load-balancer-type: external`).

### Automatic DNS records with ExternalDNS

Without help, you would copy the load balancer DNS name into Route 53 by hand after every deployment. **ExternalDNS** does it for you: it watches Ingress, Service and HTTPRoute objects, reads their hostnames, and creates (and later deletes) the matching Route 53 records.

It only touches records it owns: next to each record it writes a TXT "ownership" record (`extdns-...`) with the cluster name. Your existing records are never modified.

1. IAM policy (file `external-dns-iam-policy.json`) and IRSA ServiceAccount:
```bash
aws iam create-policy --policy-name ExternalDNSPolicy --policy-document file://external-dns-iam-policy.json
eksctl create iamserviceaccount --cluster=$CLUSTER --region $REGION --namespace=external-dns \
  --name=external-dns \
  --attach-policy-arn=arn:aws:iam::$ACCOUNT_ID:policy/ExternalDNSPolicy \
  --override-existing-serviceaccounts --approve
```

2. Install with Helm, using `external-dns-values.yaml` (**edit `domainFilters` to your domain first**):
```bash
helm repo add external-dns https://kubernetes-sigs.github.io/external-dns/
helm repo update
helm install external-dns external-dns/external-dns -n external-dns --version 1.23.0 -f external-dns-values.yaml
kubectl rollout status deploy/external-dns -n external-dns
kubectl logs -n external-dns deploy/external-dns --tail=5
# expect: "Applying provider record filter for domains: [afriqhome.com. ...]" and "All records are already up to date"
```

**DNS caching warning:** do **not** open a hostname in your browser before ExternalDNS has created it. Your laptop / router then remembers "this name does not exist" for as long as the zone's SOA negative TTL (Route 53 default: **1 day**). Wait for the `Desired change: CREATE <host>` log line first. If you got caught, check with `nslookup <host> 8.8.8.8` and flush your local cache (`ipconfig /flushdns` on Windows, `sudo dscacheutil -flushcache; sudo killall -HUP mDNSResponder` on Mac). Instructors: lower the negative TTL of the zone (last field of the SOA record) to 60 seconds before class.

### Create sample applications 

(Let's call them app1 and app2). 

Create files for each app:

App 1 manifest
```yaml
#app1.yaml 
apiVersion: apps/v1
kind: Deployment
metadata:
  name: app1
spec:
  replicas: 2
  selector:
    matchLabels:
      app: app1
  template:
    metadata:
      labels:
        app: app1
    spec:
      containers:
      - name: app1
        image: nginx:1.27
        ports:
        - containerPort: 80
---
apiVersion: v1
kind: Service
metadata:
  name: app1-service
spec:
  type: ClusterIP
  ports:
  - port: 80
    targetPort: 80
  selector:
    app: app1
```

App 2 manifest
```yaml
#app2.yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: app2
spec:
  replicas: 2
  selector:
    matchLabels:
      app: app2
  template:
    metadata:
      labels:
        app: app2
    spec:
      containers:
      - name: app2
        image: httpd:2.4
        ports:
        - containerPort: 80
---
apiVersion: v1
kind: Service
metadata:
  name: app2-service
spec:
  type: ClusterIP
  ports:
  - port: 80
    targetPort: 80
  selector:
    app: app2
```
Ingress resource manifest (`ingress.yaml`). Replace the hosts with your own subdomains before applying it.

**Note on `spec.ingressClassName: alb`:** This is the post-K8s-1.22 syntax. The older `kubernetes.io/ingress.class: alb` annotation still works for backward compatibility, but it is deprecated. Use the modern `spec.ingressClassName` field on any K8s cluster running 1.22 or newer (which includes every supported EKS version in 2026).

```yaml
#ingress.yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: multi-app-ingress
  annotations:
    alb.ingress.kubernetes.io/scheme: internet-facing
    alb.ingress.kubernetes.io/target-type: ip
    alb.ingress.kubernetes.io/listen-ports: '[{"HTTP":80},{"HTTPS":443}]'
    alb.ingress.kubernetes.io/ssl-redirect: "443"   # http:// is redirected to https://
    # No certificate-arn needed: the controller picks the ACM certificate that matches the hosts below
spec:
  ingressClassName: alb
  rules:
  - host: app1.afriqhome.com      # replace with your own subdomain (ExternalDNS creates the record)
    http:
      paths:
      - path: /
        pathType: Prefix
        backend:
          service:
            name: app1-service
            port:
              number: 80
  - host: app2.afriqhome.com      # replace with your own subdomain
    http:
      paths:
      - path: /
        pathType: Prefix
        backend:
          service:
            name: app2-service
            port:
              number: 80
```

```bash
kubectl apply -f app1.yaml
kubectl apply -f app2.yaml
kubectl apply -f ingress.yaml
kubectl get ingress multi-app-ingress
# ADDRESS shows the ALB DNS name after ~30 seconds
kubectl describe ingress multi-app-ingress | grep -A5 Events
# expect: SuccessfullyReconciled
```
Watch ExternalDNS create the records (within 30 seconds):
```bash
kubectl logs -n external-dns deploy/external-dns | grep "Desired change"
# expect: CREATE app1.afriqhome.com A ... CREATE app2.afriqhome.com A ...
```

## Test

The ALB takes 2 to 3 minutes to become active. Then:
```bash
curl https://app1.afriqhome.com      # nginx welcome page
curl https://app2.afriqhome.com      # "It works!" (httpd)
curl -I http://app1.afriqhome.com    # 301 redirect to https://
```
Or open both URLs in your browser: the padlock shows the ACM certificate. **One** ALB serves both apps (compare with chapter 06, where every LoadBalancer service created its own load balancer).

## Gateway API: the modern successor to Ingress

### What is Gateway API?

The Kubernetes Ingress API has been around since 1.1 and is showing its age. The community's answer is the **Gateway API**, a set of CRDs (`GatewayClass`, `Gateway`, `HTTPRoute`, `TCPRoute`, `GRPCRoute`, ...) that replace and extend Ingress.

### A brief history

Ingress shipped in K8s 1.1 (2015). It worked, but every controller layered vendor-specific annotations (`nginx.ingress.kubernetes.io/...`, `alb.ingress.kubernetes.io/...`) to expose features the spec did not cover. By 2019, traffic-splitting, header-based routing, and multi-team ownership of one load balancer were universally requested and universally implemented as annotation soup. SIG-Network started the Gateway API project that year. The core resources reached **GA (v1.0) in October 2023**, and the current standard channel as of this rewrite is **v1.6.0** (which also moved TCPRoute and UDPRoute to the standard channel).

### Why it matters

Gateway API splits responsibility across **3 resources** so each one has a clear owner:

- **GatewayClass** — defines a class of gateways (e.g., "AWS ALB"). Installed by the platform team / cluster admin.
- **Gateway** — an actual listener (ports, protocols, TLS). Owned by the cluster admin or app team lead.
- **HTTPRoute** (or `TCPRoute`, `GRPCRoute`, etc.) — the routing rules. Owned by app developers.

This gives you **header-based routing, weighted traffic splitting (canaries / blue-green), and cross-namespace routing** in the spec itself, with no controller-specific annotations.

### When to use vs not use it

- **Stick with Ingress** for simple host/path routing on a single team's load balancer. It is still fully supported, and tooling / examples are everywhere.
- **Move to Gateway API** when you need traffic-splitting, header-based routing, gRPC, or a clear platform-team / app-team split. New greenfield platforms in 2026 should default to Gateway API.

---

## Practice: Gateway API on EKS with the AWS Load Balancer Controller

### Prerequisites

- Everything from the Ingress practice above: the controller (v2.14 or newer; we installed v3.6.0), the Gateway API CRDs (installed in step 4, before the controller), ExternalDNS, the ACM certificate.
- `app1` and `app2` from the Ingress practice (re-apply `app1.yaml` and `app2.yaml` if you deleted them).

Check that the controller enabled its Gateway API support:
```bash
kubectl logs -n kube-system deploy/aws-load-balancer-controller | grep -m3 "gateway.k8s.aws/alb"
# expect lines like: "Starting EventSource","controller":"gateway.k8s.aws/alb"
```
If you installed the CRDs **after** the controller, restart it: `kubectl rollout restart deploy/aws-load-balancer-controller -n kube-system`.

### The manifests (folder `gateway-api/`)

| File | Resource | Owner | What it does |
|---|---|---|---|
| `01-gatewayclass.yaml` | `GatewayClass` | platform team | "gateways of class `alb` are built by the AWS controller" |
| `02-gateway.yaml` | `LoadBalancerConfiguration` + `Gateway` | platform team | one internet-facing ALB, listeners HTTP:80 and HTTPS:443 with the ACM certificate |
| `03-httproute.yaml` | 2 x `HTTPRoute` | app team | `gateway.afriqhome.com`: header routing + 50/50 split between app1 and app2; HTTP redirected to HTTPS |
| `04-targetgroup-config.yaml` | 2 x `TargetGroupConfiguration` | app team | register pod IPs in the ALB (our services are ClusterIP) |

The interesting part of the HTTPRoute, things a plain Ingress cannot do without vendor annotations:
```yaml
  hostnames:
    - gateway.afriqhome.com
  rules:
    - matches:                      # header-based routing
        - headers:
            - name: x-version
              value: v2
      backendRefs:
        - name: app2-service
          port: 80
    - backendRefs:                  # weighted split (canary)
        - name: app1-service
          port: 80
          weight: 50
        - name: app2-service
          port: 80
          weight: 50
```

**Note on `04-targetgroup-config.yaml`:** without it the Gateway stays `PROGRAMMED Unknown` and `kubectl describe gateway` shows `TargetGroup port is empty. When using Instance targets, your service must be of type 'NodePort' or 'LoadBalancer'`. The ALB Gateway default is to register nodes; the TargetGroupConfiguration switches to pod IPs (the equivalent of `alb.ingress.kubernetes.io/target-type: ip`).

### Apply + verify

Put your certificate ARN in `02-gateway.yaml` (or substitute it on the fly as below), and your subdomain in `03-httproute.yaml`:
```bash
cd gateway-api
CERT_ARN=$(aws acm list-certificates --region $REGION --query "CertificateSummaryList[?DomainName=='*.afriqhome.com'].CertificateArn" --output text)

kubectl apply -f 01-gatewayclass.yaml
sed "s|<your-acm-certificate-arn>|$CERT_ARN|" 02-gateway.yaml | kubectl apply -f -
kubectl apply -f 03-httproute.yaml
kubectl apply -f 04-targetgroup-config.yaml

kubectl get gatewayclass,gateway,httproute
kubectl wait --for=condition=Programmed gateway/my-gateway --timeout=300s
# PROGRAMMED becomes True after 2 to 3 minutes; ADDRESS is the ALB DNS name
kubectl logs -n external-dns deploy/external-dns | grep "gateway.afriqhome.com"
# expect: Desired change: CREATE gateway.afriqhome.com A
```

### Test

```bash
# 50/50 split: count which app answers
for i in $(seq 1 20); do curl -s https://gateway.afriqhome.com | grep -m1 -oE "Welcome to nginx|It works"; done | sort | uniq -c

# header routing: always app2
for i in $(seq 1 5); do curl -s -H "x-version: v2" https://gateway.afriqhome.com | grep -m1 -oE "Welcome to nginx|It works"; done | sort | uniq -c

# http -> https
curl -I http://gateway.afriqhome.com
```
Change the weights to `90` / `10`, re-apply `03-httproute.yaml`, and run the loop again: that is a canary release.

### Cleanup

```bash
kubectl delete -f 04-targetgroup-config.yaml -f 03-httproute.yaml --ignore-not-found
kubectl delete -f 02-gateway.yaml --ignore-not-found      # deletes the Gateway ALB
kubectl delete -f 01-gatewayclass.yaml --ignore-not-found
cd ..
kubectl delete -f ingress.yaml --ignore-not-found          # deletes the Ingress ALB
kubectl delete -f app1.yaml -f app2.yaml --ignore-not-found
# ExternalDNS removes app1/app2/gateway.afriqhome.com from Route 53 within a minute
```
**Keep** the AWS Load Balancer Controller, ExternalDNS and the Gateway API CRDs if you continue with the next chapters: ArgoCD (21), Istio (25) and the Labs use them. To remove them at the very end:
```bash
helm uninstall external-dns -n external-dns
helm uninstall aws-load-balancer-controller -n kube-system
kubectl delete -f https://raw.githubusercontent.com/kubernetes-sigs/aws-load-balancer-controller/refs/heads/main/config/crd/gateway/gateway-crds.yaml
kubectl delete -f https://github.com/kubernetes-sigs/gateway-api/releases/download/v1.6.0/standard-install.yaml
```
