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
| EKS add-ons | latest for 1.36 | `terraform/eks.tf` | VPC CNI (NetworkPolicy enforcement on), CoreDNS, kube-proxy, Pod Identity agent, metrics-server, EBS CSI |
| IAM | module `terraform-aws-modules/eks-pod-identity` 2.x | `terraform/pod-identity.tf` | one role per controller with EKS Pod Identity (no OIDC, no annotations) |
| Gateway API CRDs | v1.6.0 standard | local chart `terraform/charts/gateway-api-crds` | `Gateway`, `HTTPRoute`, ... |
| AWS Load Balancer Controller | 3.6.0 | Helm | builds the NLB of the Istio ingress Service |
| Istio | 1.30.6 (charts base, istiod, gateway) | Helm | sidecar mesh, mesh-wide STRICT mTLS, Gateway API implementation, shared ingress |
| cert-manager | v1.21.2 | Helm | `ClusterIssuer letsencrypt` (ACME DNS-01 in Route 53) |
| ExternalDNS | 0.23.0 (chart 1.23.0) | Helm | Route 53 records from HTTPRoute hostnames, TXT ownership `owner=<cluster_name>` |
| Argo CD | v3.5.5 (chart 10.10.5) | Helm | GitOps engine, UI at `https://argocd.<domain>` |
| Platform config | local chart `terraform/charts/platform-config` | Helm | ClusterIssuer, default `gp3` StorageClass, mesh mTLS, Argo CD URL, ApplicationSet |

(The Istio Helm repository publishes charts up to 1.30.6 at the time of writing. `istioctl` 1.31 exists but its charts are not published yet.)

### Design decisions

- **One load balancer for every app.** Each app has its own `Gateway` (its own listeners, hostname and certificate), but all Gateways are bound to the same `istio-ingress` Service with `spec.addresses` (Istio "manual deployment" mode). Adding an app never creates an AWS load balancer. Istio reports the NLB address in each Gateway status (`PROGRAMMED True`).
- **A certificate per app, from cert-manager** (Let's Encrypt, DNS-01): no dependency on ACM, issued in about 90 seconds, renewed automatically. DNS-01 means the app does not need to be reachable to get its certificate.
- **The Gateway and the Certificate of an app live in `istio-ingress`**, next to the Envoy pods that read the TLS secret. The `HTTPRoute` lives in the app namespace. Each Gateway only accepts routes from its own app namespace (`allowedRoutes` selector): one team cannot hijack another team's hostname.
- **App name and environment come from the path** (`apps/<name>/<env>.yaml`), never from the file content: the folder name is the app, the file name is the environment. A team cannot deploy under another name by mistake.
- **Pod Identity for every controller** (load balancer controller, ExternalDNS, cert-manager, EBS CSI, VPC CNI). The Route 53 permissions of ExternalDNS and cert-manager are limited to the one hosted zone.
- **ExternalDNS `policy: sync` + TXT registry**: it deletes the records it created when an app goes away, and never touches records it does not own (the existing records of the zone stayed untouched during all tests).
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

## 7. Operations

| Task | How |
|---|---|
| Upgrade a platform component | change its version in `var.versions` (or `terraform.tfvars`), `terraform apply`. Read the component release notes first (CRD changes). |
| Change `charts/platform-config` or `charts/gateway-api-crds` | **bump `version:` in its `Chart.yaml`**, then `terraform apply`. Terraform only redeploys a local chart when its version changes: without the bump, `apply` says "0 changed" and nothing happens. |
| Change what every app gets | edit `app-template` in `platform-gitops` (e.g. add a NetworkPolicy), run `./scripts/validate.sh`, merge: Argo CD updates every app within 3 minutes. |
| Upgrade Kubernetes | `kubernetes_version = "1.37"`, `terraform apply` (control plane, then add-ons, then node group rolling update; PDBs keep the apps up). One minor version at a time. |
| More capacity | `node_max_size` / `node_desired_size` / `node_instance_types`, `terraform apply`. |
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

### 8.8 Useful commands
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
`terraform destroy` first runs `scripts/pre-destroy.sh` (resource `terraform_data.pre_destroy`): it deletes the ApplicationSet, waits until Argo CD has deleted every app, deletes the Argo CD routes, and waits until ExternalDNS has removed every Route 53 record it owns. Only then are Argo CD, ExternalDNS, the load balancer controller (and its NLB), the cluster and the VPC deleted. This order matters: if the controller goes away first, the NLB and the DNS records are left behind.

DESTROY_RESULTS

## 10. Costs (us-east-1, on-demand, approximate)

| Item | Monthly |
|---|---|
| EKS control plane | ~$73 |
| 3 x t3.large nodes | ~$180 |
| NAT gateway (1) + data | ~$35+ |
| NLB (1, shared by all apps) | ~$17+ |
| KMS key (secrets encryption), Route 53 queries, EBS | a few $ |
| **Total** | **~$310 / month** for the platform, whatever the number of apps (until the nodes are full) |
