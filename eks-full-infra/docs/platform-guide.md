# EKS platform: guide for the platform team

This document explains how the shared EKS platform is built, how to create and destroy it, how app onboarding works under the hood, and how to operate and troubleshoot it. App teams have their own, shorter guide: the README of the GitOps repository [utrains/platform-gitops](https://github.com/utrains/platform-gitops).

Everything below was run end to end on 2026-10-19 (EKS 1.36, us-east-1, domain `afriqhome.com`): `terraform apply` from an empty account, three apps added / updated / removed through Git, `terraform destroy` with nothing left behind.

## 1. What the platform gives an app team

An app team creates one folder and one small file in the GitOps repo: `apps/<name>/<env>.yaml` (usually just the image and the port), opens a pull request, and merges it. About **4 to 5 minutes later**, without any ticket to the platform team, the app runs:

- in its own namespace `<name>-<env>`, with an Istio sidecar on every pod (mutual TLS between all services),
- behind its own subdomain `https://<name>-<env>.<domain>` (`https://<name>.<domain>` for prod),
- with a trusted Let's Encrypt certificate that renews by itself,
- with a DNS record that appears and disappears with the app,
- with probes, resource limits, a PodDisruptionBudget, zone spreading and optional autoscaling.

Deleting the folder (or the file) removes everything again, including the namespace, the certificate, the TLS secret and the DNS record.

## 2. Architecture

```
  GitHub: utrains/platform-gitops                           GitHub Actions: scripts/validate.sh
    app-template/        (Helm chart, platform team)        on every pull request
    apps/<name>/<env>.yaml (one per app and env)
                │ polled every 3 min
                v
  Argo CD ApplicationSet "apps" ──> one Application per file ──> chart app-template
                                                                     │
                        Route 53 (public zone <domain>)              │ creates
     <name>-<env>.<domain>  ──ALIAS──┐                               v
     argocd.<domain>        ──ALIAS──┤      ExternalDNS writes these records
                                     v
                     NLB (one, internet-facing, TCP 80/443)        AWS Load Balancer Controller
                                     │
            ┌────────────────────────v─────────────────────────┐
            │ namespace istio-ingress                          │
            │   istio-ingress Deployment (2-5 Envoy pods)      │   TLS ends here with the
            │   Gateway <name>-<env>  (one per app)            │   cert-manager certificates
            │   Certificate/Secret <name>-<env>-tls            │
            └────────────────────────┬─────────────────────────┘
                 HTTPRoute, mutual TLS│
            ┌────────────────────────v─────────────────────────┐
            │ namespace <name>-<env>   (istio-injection)       │
            │   Deployment <name>, Service <name>, PDB, HPA    │
            └──────────────────────────────────────────────────┘
```

### Components

| Component | Version | Where | Role |
|---|---|---|---|
| VPC | module `terraform-aws-modules/vpc` 6.x | `terraform/vpc.tf` | 3 AZs, private subnets for nodes and pods, public subnets for the NLB, 1 NAT gateway |
| EKS | 1.36, module `terraform-aws-modules/eks` 21.x | `terraform/eks.tf` | control plane (secrets encrypted with KMS) + managed node group (3 x t3.large, 2 to 5) |
| EKS add-ons | latest for 1.36 | `terraform/eks.tf` | VPC CNI (NetworkPolicy enforcement on), CoreDNS, kube-proxy, Pod Identity agent, metrics-server, EBS CSI, EFS CSI |
| IAM | module `terraform-aws-modules/eks-pod-identity` 2.x | `terraform/pod-identity.tf` | one role per controller with EKS Pod Identity (no OIDC, no annotations) |
| Gateway API CRDs | v1.6.0 standard | local chart `terraform/charts/gateway-api-crds` | `Gateway`, `HTTPRoute`, ... |
| AWS Load Balancer Controller | 3.6.0 | Helm | builds the NLB of the Istio ingress Service |
| Istio | 1.30.6 (charts base, istiod, gateway) | Helm | sidecar mesh, mesh-wide STRICT mTLS, Gateway API implementation, shared ingress |
| cert-manager | v1.21.2 | Helm | `ClusterIssuer letsencrypt` (ACME DNS-01 in Route 53) |
| ExternalDNS | 0.23.0 (chart 1.23.0) | Helm | Route 53 records from HTTPRoute hostnames, TXT ownership `owner=<cluster_name>` |
| Argo CD | v3.5.5 (chart 10.10.5) | Helm | GitOps engine, UI at `https://argocd.<domain>` |
| EFS | `aws_efs_file_system` | `terraform/efs.tf` | one encrypted file system (elastic throughput), a mount target per AZ, NFS (2049) from the nodes only |
| Platform config | local chart `terraform/charts/platform-config` | Helm | ClusterIssuer, StorageClasses `gp3` (default, EBS) and `efs` (one access point per PVC), mesh mTLS, Argo CD URL, HTTPRoute RBAC for teams, Argo CD Application `platform-addons`, ApplicationSets `teams` and `apps` |
| Prometheus + Grafana | kube-prometheus-stack 92.11.0 | **Argo CD**, `platform-gitops/platform-addons` | metrics (7 days on a 20 Gi gp3 volume), Grafana at `https://grafana.<domain>` with Prometheus and Loki data sources |
| Loki | chart 7.3.0 (Loki 3.6) | **Argo CD**, `platform-gitops/platform-addons` | logs, single binary, 7 days on a 20 Gi gp3 volume |
| Fluent Bit | chart 0.58.3 (Fluent Bit 5.1) | **Argo CD**, `platform-gitops/platform-addons` | one pod per node, ships every container log to Loki with the labels `namespace`, `pod`, `container` |
| Team namespaces | chart `platform-gitops/team-template` | **Argo CD**, ApplicationSet `teams` | per team and environment: namespace, RBAC, ResourceQuota, LimitRange, NetworkPolicies, wildcard HTTPS gateway |

(The Istio Helm repository publishes charts up to 1.30.6 at the time of writing. `istioctl` 1.31 exists but its charts are not published yet.)

### Design decisions

- **One load balancer for every app.** Each app has its own `Gateway` (its own listeners, hostname and certificate), but all Gateways are bound to the same `istio-ingress` Service with `spec.addresses` (Istio "manual deployment" mode). Adding an app never creates an AWS load balancer. Istio reports the NLB address in each Gateway status (`PROGRAMMED True`).
- **A certificate per app, from cert-manager** (Let's Encrypt, DNS-01): no dependency on ACM, issued in about 90 seconds, renewed automatically. DNS-01 means the app does not need to be reachable to get its certificate.
- **The Gateway and the Certificate of an app live in `istio-ingress`**, next to the Envoy pods that read the TLS secret. The `HTTPRoute` lives in the app namespace. Each Gateway only accepts routes from its own app namespace (`allowedRoutes` selector): one team cannot hijack another team's hostname.
- **App name and environment come from the path** (`apps/<name>/<env>.yaml`), never from the file content: the folder name is the app, the file name is the environment. A team cannot deploy under another name by mistake.
- **Pod Identity for every controller** (load balancer controller, ExternalDNS, cert-manager, EBS CSI, VPC CNI). The Route 53 permissions of ExternalDNS and cert-manager are limited to the one hosted zone.
- **ExternalDNS `policy: sync` + TXT registry**: it deletes the records it created when an app goes away, and never touches records it does not own (the existing records of the zone stayed untouched during all tests).
- **Terraform builds, Argo CD runs.** Terraform installs what the cluster needs to start and everything wired to AWS (VPC, EKS, add-ons, IAM, EFS, the load balancer controller, cert-manager, ExternalDNS, Istio, Argo CD itself). Argo CD then installs from Git what changes often and needs no AWS wiring: the observability add-ons, the team namespaces and the apps. Upgrading Grafana or adding a team is a pull request, not a `terraform apply`. One `terraform apply` still builds everything: its last step creates the Argo CD objects that pull the rest.
- **Team isolation, one control per risk.** Namespace per team and environment (blast radius); RBAC groups `<team>-admins` and `<team>-developers`, developers read-only in prod (who can change what); ResourceQuota and LimitRange (one team cannot starve the others), with `services.loadbalancers: 0` and `services.nodeports: 0` (no team can bypass the shared load balancer); NetworkPolicies, default deny for incoming traffic, allowed only from the same namespace, the ingress gateway and Prometheus (no lateral movement between teams).
- **EBS by default, EFS when pods share files.** `gp3` (EBS, ReadWriteOnce) is the default StorageClass: fast, cheap, one pod at a time, one AZ. `efs` (ReadWriteMany) is for data several pods read and write at once, across AZs; each claim gets its own access point (directory, owner) on the single cluster file system.
- **Two guardrails against a bad app request**: the GitHub Actions check refuses invalid folder or file names before the merge, and the ApplicationSet sanitizes Application and namespace names so that an invalid request that reaches `main` only breaks itself (see 8.6).

## 3. Prerequisites

- An AWS account and credentials with admin rights (`aws sts get-caller-identity` works).
- A **public Route 53 hosted zone** for your domain (here `afriqhome.com`).
- Tools: Terraform >= 1.9, AWS CLI v2, kubectl, Helm 3, bash (Git Bash on Windows; `terraform destroy` runs a bash script).
- The GitOps repository (`utrains/platform-gitops`), readable by Argo CD (public, or add credentials to Argo CD).

## 4. Create the platform

```bash
cd eks-full-infra/terraform
cp terraform.tfvars.example terraform.tfvars    # domain, gitops_repo_url, gitops_revision
terraform init
terraform plan
terraform apply                                 # 20 to 25 minutes
```
```bash
$(terraform output -raw configure_kubectl)       # aws eks update-kubeconfig --name platform --region us-east-1
terraform output argocd_url                      # https://argocd.afriqhome.com
eval "$(terraform output -raw argocd_admin_password_command)"
```
Log in to Argo CD as `admin`, then change the password (User Info > Update password) and delete the secret `argocd-initial-admin-secret`.

## 5. Verify

One script proves every required outcome without deploying a real application. It creates its test objects, prints `PASS`/`FAIL` per check and cleans up:
```bash
bash scripts/readiness-check.sh
```
| Section | What it proves |
|---|---|
| 1. Cluster and add-ons | nodes Ready, every EKS add-on `ACTIVE`, every controller available |
| 2. GitOps | the Argo CD applications of the add-ons and the teams are `Synced/Healthy` |
| 3. Storage | StorageClasses `gp3` (default) and `efs`; two pods on **different nodes** mount one EFS volume, one writes a file, the other reads it |
| 4. Multi-tenancy | quota, limits and default-deny policy in each team namespace; `kubectl auth can-i` for developers and admins (dev vs prod vs another team); a `LoadBalancer` Service is refused by the quota; a pod of another team cannot reach the team's service, a pod of the same namespace can |
| 5. Ingress | **one** AWS load balancer for all the Gateways; a test service published through the team gateway answers over HTTPS with a trusted certificate |
| 6. Observability | Prometheus, Grafana, Loki and Fluent Bit running; through Grafana's API, Prometheus has metrics and Loki has logs for a team namespace |

Result of the test run on 2026-10-20: `== 46 passed, 0 failed ==`.

Manual checks:
```bash
kubectl get pods -A | grep -vE "Running|Completed"      # nothing (except pods being created)
kubectl get clusterissuer letsencrypt                    # READY True
kubectl get applicationset apps -n argocd -o jsonpath='{range .status.conditions[*]}{.type}={.status}{"\n"}{end}'
# ErrorOccurred=False  ParametersGenerated=True  ResourcesUpToDate=True
kubectl get applications -n argocd                       # one per apps/<name>/<env>.yaml, Synced / Healthy
kubectl get certificates,gateways -n istio-ingress       # READY True / PROGRAMMED True, all on the same NLB
kubectl get httproutes -A
```
Results of the test run:
```
NAME              READY   SECRET            AGE        # certificates: issued ~90s after the app appeared
argocd-tls        True    argocd-tls        111s
hello-dev-tls     True    hello-dev-tls     102s
whoami-prod-tls   True    whoami-prod-tls   103s

NAME          CLASS   ADDRESS                                                          PROGRAMMED
argocd        istio   k8s-istioing-istioing-6f7e6030cf-...elb.us-east-1.amazonaws.com  True
hello-dev     istio   k8s-istioing-istioing-6f7e6030cf-...elb.us-east-1.amazonaws.com  True
whoami-prod   istio   k8s-istioing-istioing-6f7e6030cf-...elb.us-east-1.amazonaws.com  True
```
From outside:
```bash
curl -sI https://whoami.afriqhome.com          # HTTP/1.1 200, server: istio-envoy
curl -sI http://whoami.afriqhome.com           # 301 -> https://whoami.afriqhome.com/
echo | openssl s_client -connect whoami.afriqhome.com:443 -servername whoami.afriqhome.com 2>/dev/null | openssl x509 -noout -issuer -subject
# issuer=C=US, O=Let's Encrypt, CN=YR2   subject=CN=whoami.afriqhome.com
curl -s https://whoami.afriqhome.com | grep X-Forwarded-Client-Cert
# By=spiffe://cluster.local/ns/whoami-prod/sa/default;...   <- the gateway -> pod hop is mutual TLS
```

## 6. How app onboarding works

1. The app team adds `apps/<name>/<env>.yaml` in `platform-gitops` through a pull request. GitHub Actions runs `scripts/validate.sh` (names, environment, chart rendering). Review it like any code change (CODEOWNERS).
2. The ApplicationSet `apps` (git files generator, `apps/*/*.yaml`) polls the repository every 3 minutes and creates the Argo CD Application `<name>-<env>` with:
   - the chart `app-template` of the same repository,
   - Helm values `platform.*` (domain, issuer, ingress Service, NLB hostname: set by Terraform) and `app.*` (the file content, plus `name` = folder name and `env` = file name, which always win),
   - automated sync with prune and self-heal, and the resources finalizer (deleting the Application deletes everything it created).
3. Argo CD renders the chart and applies it. The chart validates the name (`^[a-z][a-z0-9-]{0,28}[a-z0-9]$`) and the env (`dev`, `staging`, `prod`) and fails the sync with a clear message otherwise.
4. cert-manager solves the DNS-01 challenge in Route 53 and writes the TLS secret (~90 s). Istio programs the listeners on the shared ingress. ExternalDNS creates the ALIAS record (~30 s, then Route 53 propagation).

Measured: push of a new app -> HTTPS 200 in **~4.5 minutes**. Update (`replicas: 3` -> `4`): applied at the next poll. Removal of a folder -> namespace, certificate, secret, gateway, routes and DNS record gone in **~1.5 minutes** after the poll.

### Naming convention (chart `app-template/templates/_helpers.tpl`)

| Object | Name | Namespace |
|---|---|---|
| Namespace (label `istio-injection: enabled`) | `<name>-<env>` | |
| Deployment, Service, PDB, HPA | `<name>` | `<name>-<env>` |
| HTTPRoute (HTTPS), HTTPRoute (HTTP -> HTTPS redirect) | `<name>`, `<name>-redirect` | `<name>-<env>` |
| Gateway | `<name>-<env>` | `istio-ingress` |
| Certificate and its Secret | `<name>-<env>-tls` | `istio-ingress` |
| Argo CD Application | `<name>-<env>` | `argocd` |
| Subdomain | `<name>-<env>.<domain>`, prod: `<name>.<domain>` | |

### Team namespaces

A team gets its namespaces with one file in `platform-gitops`: `teams/<team>.yaml` (the file name is the team name). The ApplicationSet `teams` creates the Argo CD Application `team-<team>`, which renders `team-template` and creates, for each environment in `envs`:

| Object | Name | Namespace |
|---|---|---|
| Namespace (labels `platform/team`, `platform/env`, `istio-injection: enabled`) | `<team>-<env>` | |
| RoleBinding group `<team>-admins` -> ClusterRole `admin` | `<team>-admins` | `<team>-<env>` |
| RoleBinding group `<team>-developers` -> `edit` (`view` in prod) | `<team>-developers` | `<team>-<env>` |
| ResourceQuota (CPU, memory, pods, PVCs, storage, 0 LoadBalancer, 0 NodePort) and LimitRange | `<team>-quota`, `<team>-defaults` | `<team>-<env>` |
| NetworkPolicies | `default-deny-ingress`, `allow-same-namespace`, `allow-ingress-gateway`, `allow-monitoring` | `<team>-<env>` |
| Wildcard Certificate and Gateway on the shared ingress | `<team>-<env>-tls`, `<team>-<env>` | `istio-ingress` |
| HTTP -> HTTPS redirect for the whole wildcard | `https-redirect` | `<team>-<env>` |

The team publishes a service with an `HTTPRoute` in its namespace, parent the Gateway `<team>-<env>` (section `https`), hostname `<anything>.<team>-<env>.<domain>` (prod: `<anything>.<team>.<domain>`). ExternalDNS creates the record; the wildcard certificate already covers it.

People get the groups through EKS access entries: map the team's IAM role to the Kubernetes groups, for example
```bash
aws eks create-access-entry --cluster-name platform --principal-arn arn:aws:iam::<account>:role/payments-developers \
  --kubernetes-groups payments-developers
```

## 7. Operations

| Task | How |
|---|---|
| Upgrade a platform component | change its version in `var.versions` (or `terraform.tfvars`), `terraform apply`. Read the component release notes first (CRD changes). |
| Change `charts/platform-config` or `charts/gateway-api-crds` | **bump `version:` in its `Chart.yaml`**, then `terraform apply`. Terraform only redeploys a local chart when its version changes: without the bump, `apply` says "0 changed" and nothing happens. |
| Change what every app gets | edit `app-template` in `platform-gitops` (e.g. add a NetworkPolicy), run `./scripts/validate.sh`, merge: Argo CD updates every app within 3 minutes. |
| Upgrade Kubernetes | `kubernetes_version = "1.37"`, `terraform apply` (control plane, then add-ons, then node group rolling update; PDBs keep the apps up). One minor version at a time. |
| More capacity | `node_max_size` / `node_desired_size` / `node_instance_types`, `terraform apply`. |
| Change an observability add-on (version, retention, values) | edit `platform-addons/` in `platform-gitops`, pull request, merge: Argo CD applies it. |
| Add or change a team | add or edit `teams/<team>.yaml` in `platform-gitops` (`./scripts/validate.sh` checks it), merge. Removing the file deletes the team's namespaces and everything in them. |
| See every app | Argo CD UI, or `kubectl get applications -n argocd -l app.kubernetes.io/part-of=apps` |
| Force Argo CD to read Git now | Argo CD UI > the app > Refresh, or `kubectl annotate application <name>-<env> -n argocd argocd.argoproj.io/refresh=normal --overwrite` |

## 8. Troubleshooting

Problems met while building and testing the platform, with their fix (all fixes are in the code).

### 8.1 Pods in an injected namespace are never created
`kubectl describe rs` shows `failed calling webhook "object.sidecar-injector.istio.io" ... context deadline exceeded`.
The EKS control plane cannot reach istiod on port **15017**. Fixed by the node security group rule `istio_webhook` in `eks.tf`.

### 8.2 An app answers only half of the requests
`curl` times out about every other request; the gateway logs show `0 DC downstream_remote_disconnect` for some pod IPs and `200` for others. The working pods are on the **same node** as the gateway pod. By default the EKS module only allows node-to-node traffic on ports 1025 to 65535, so an app listening on port 80 is unreachable from other nodes. Fixed by the rule `nodes_all_traffic` in `eks.tf`.

### 8.3 `terraform apply` fails with "cannot re-use a name that is still in use"
A previous apply left a failed Helm release that Terraform does not track. Remove it, then apply again:
```bash
helm list -A --failed
helm uninstall <release> -n <namespace>
terraform apply
```

### 8.4 A certificate stays `READY False`
```bash
kubectl describe certificate <name>-<env>-tls -n istio-ingress
kubectl get challenges -A
kubectl logs -n cert-manager deploy/cert-manager | grep -i -E "error|route53"
```
Usual causes: the hosted zone is not the one in `terraform.tfvars`; Let's Encrypt rate limits (50 certificates per week per domain: use `letsencrypt_server` = the staging URL when testing a lot).

### 8.5 The URL does not resolve on my laptop but works elsewhere
Your resolver cached "name not found" because you opened the URL before ExternalDNS created the record. Check with `nslookup <host> 8.8.8.8`, flush the local cache (`ipconfig /flushdns`), and lower the negative TTL of the zone (last field of the SOA record, here set to 60 s).

### 8.6 One bad app request blocks every other app
Without protection, an Application with an invalid name (folder `Bad_App`) makes the whole ApplicationSet fail: `ErrorOccurred=True ... Application "Bad_App-dev" is invalid`, and no other app can be created, updated or **deleted**. Two guardrails are in place:
- the GitHub Actions check (`scripts/validate.sh`) refuses the pull request,
- the ApplicationSet sanitizes the Application and namespace names (`bad-app-dev`); the chart still receives `Bad_App` and fails only that Application, with the message `app.name "Bad_App" is invalid ...`. Every other app keeps syncing.

### 8.7 A removed app left its namespace or TLS secret
Fixed: the chart owns the Namespace (Argo CD deletes it with the app; `CreateNamespace` would keep it), and cert-manager runs with `enableCertificateOwnerRef` (the Secret is deleted with its Certificate).

### 8.8 `terraform destroy` leaves the NLB, the DNS records and the VPC behind
Symptoms: `[pre-destroy] ExternalDNS records left: 4`, `Unable to uninstall Helm release istio-ingress: context deadline exceeded`, `DependencyViolation` on the subnets and the internet gateway. The Pod Identity agent logs `Post "https://eks-auth.us-east-1.api.aws/...": i/o timeout`.
Cause: Terraform deleted the NAT gateway in parallel with the cleanup: the nodes lost internet access, so the controllers could no longer call AWS (Pod Identity needs the EKS Auth endpoint). Fixed: the controllers and `terraform_data.pre_destroy` depend on `module.vpc`, so the network is destroyed last.
If it ever happens again: `terraform apply` (recreates the network and the controllers), `helm uninstall` any release Helm lists as failed, then `terraform destroy`.

### 8.9 `terraform apply` was interrupted: the cluster exists but is not in the state
The next plan wants to create `module.eks.aws_eks_cluster.this[0]` although `aws eks list-clusters` shows it; an apply fails with "already exists". `terraform import` on the command line fails in this module ("The count value depends on resource attributes that cannot be determined until apply"). Use an import block instead, in a temporary file `import.tf`:
```hcl
import {
  to = module.eks.aws_eks_cluster.this[0]
  id = "platform"
}
```
`terraform plan` must show `1 to import` and no replacement; `terraform apply`; delete `import.tf`.

### 8.10 An app with a shared volume crashloops on its first start
Example: nginx serving its web root from a new EFS volume. The volume is empty, the health path answers 404, the liveness probe kills the pod. The storage works; the app needs its content. Write it once from any pod (`kubectl exec ... -- sh -c 'echo ok > /usr/share/nginx/html/healthz.html'`), or seed it with an init container.

### 8.11 `kubectl exec ... -- cat /data/file` fails on Windows with `C:/Program Files/Git/data/file`
Git Bash rewrites arguments that look like Unix paths. Run with `MSYS_NO_PATHCONV=1` (the readiness check sets it), or wrap the command in `sh -c '...'`.

### 8.12 Useful commands
```bash
kubectl get applicationset apps -n argocd -o yaml | grep -A3 conditions
kubectl get application <name>-<env> -n argocd -o jsonpath='{.status.conditions[*].message}'
kubectl logs -n istio-ingress -l app=istio-ingress --tail=50        # access logs of the shared gateway
kubectl logs -n external-dns deploy/external-dns | grep "Desired change"
istioctl proxy-status                                                # needs istioctl 1.30.x
```

## 9. Destroy the platform

```bash
cd eks-full-infra/terraform
terraform destroy
```
`terraform destroy` first runs `scripts/pre-destroy.sh` (resource `terraform_data.pre_destroy`): it deletes the ApplicationSets `apps` and `teams` and the Application `platform-addons`, waits until Argo CD has deleted every app, team namespace and add-on, deletes the volumes left behind (StatefulSet PVCs such as Prometheus and Loki: the CSI drivers then delete the EBS volumes and EFS access points), deletes the Argo CD routes, and waits until ExternalDNS has removed every Route 53 record it owns. Only then are Argo CD, ExternalDNS, the load balancer controller (and its NLB), the EFS file system, the cluster and the VPC deleted. This order matters: if a controller goes away first, the NLB, the volumes and the DNS records are left behind.

If the script prints `WARNING: these volumes may outlive the cluster`, delete the listed EBS volumes (`aws ec2 delete-volume`) after the destroy.

Result of the test run before EFS and the add-ons (`Destroy complete! Resources: 92 destroyed.`):
```
[pre-destroy] deleting the ApplicationSet and the apps
[pre-destroy] apps left: 0
[pre-destroy] deleting the ArgoCD routes
[pre-destroy] waiting for ExternalDNS to delete its Route 53 records (owner=platform)
[pre-destroy] ExternalDNS records left: 0          <- after 26 seconds
helm_release.istio_ingress: Destruction complete after 24s   <- the NLB is deleted here
module.vpc.aws_nat_gateway.this[0]: Destruction complete ...   <- the network goes last
```
Afterwards: no EKS cluster, load balancer, VPC, Elastic IP, instance, EBS volume, IAM role/policy or log group left; the Route 53 zone is back to its original records. After the destroy with EFS, the add-ons and the teams (2026-10-20): also no EFS file system, no unattached EBS volume, no EFS security group. The KMS key of the cluster is in `PendingDeletion` for 30 days (standard AWS behaviour, no cost).

Check yourself:
```bash
aws eks list-clusters
aws elbv2 describe-load-balancers --query "LoadBalancers[].LoadBalancerName"
aws efs describe-file-systems --query "FileSystems[].Name"
aws ec2 describe-volumes --filters Name=status,Values=available --query "Volumes[].VolumeId"
aws route53 list-resource-record-sets --hosted-zone-id <zone-id> --query "ResourceRecordSets[].Name"
```

## 10. Costs (us-east-1, on-demand, approximate)

| Item | Monthly |
|---|---|
| EKS control plane | ~$73 |
| 3 x t3.large nodes | ~$180 |
| NAT gateway (1) + data | ~$35+ |
| NLB (1, shared by all apps) | ~$17+ |
| KMS key (secrets encryption), Route 53 queries, EBS (Prometheus and Loki, 40 Gi gp3), EFS (per GB stored) | ~$5+ |
| **Total** | **~$310 / month** for the platform, whatever the number of apps (until the nodes are full) |
