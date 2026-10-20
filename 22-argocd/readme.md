# ArgoCD - GitOps for Kubernetes

## What is ArgoCD?

**ArgoCD is a GitOps controller** that lives inside your Kubernetes cluster and continuously reconciles cluster state to match what is declared in a Git repository. Every change to your cluster goes through Git: commit -> PR -> merge -> ArgoCD applies it. There is no more `kubectl apply` from someone's laptop.

## A brief history

Argo CD was created at Intuit in 2018 to solve the "who pushed what, when, why?" problem they had operating dozens of Kubernetes clusters. Intuit donated the broader Argo project (Argo Workflows, Argo CD, Argo Events, Argo Rollouts) to the CNCF in 2020. Argo CD **graduated** at the CNCF in **December 2022**, joining the ranks of fully production-ready CNCF projects. It is now the dominant GitOps controller for Kubernetes, with Flux as its main peer.

## Why it matters

- **Every change is a git commit + PR review.** You get code-review on infrastructure changes for free.
- **Audit trail by design.** Git history *is* your change log.
- **Drift detection.** If someone bypasses the process and runs `kubectl edit`, ArgoCD will either warn or revert (depending on your sync policy).
- **Disaster recovery.** Lose the cluster? Apply the bootstrap manifest, point ArgoCD at the repo, the cluster rebuilds itself.

## When to use vs not use it

- **Use ArgoCD** as soon as more than one person, or one CI pipeline, applies changes to the same cluster. Day-2 ops without it gets ugly fast.
- **Skip it** for throwaway clusters and single-developer playgrounds — the operational overhead of running another controller is not worth it.

---

## Practice: install ArgoCD on EKS

### Prerequisites

- The EKS cluster `my-cluster` from chapter 00.
- For the HTTPS URL `https://argocd.afriqhome.com`: the AWS Load Balancer Controller, ExternalDNS and the ACM wildcard certificate from **chapter 08**. Without them, skip the Ingress and use a port-forward (see below).
- `kubectl` and `helm`.
- A Git repository ArgoCD can read. To do the "change Git, watch the cluster follow" test, **fork** this repository to your own GitHub account and replace `https://github.com/utrains/kubernetes-practice2.git` with your fork URL in `argocd-application.yaml`, `argocd-app-of-apps.yaml` and the files of `child-apps/`.

### Install ArgoCD with Helm (recommended)

The official `argo-cd` chart (from `argoproj/argo-helm`) lets you configure the Ingress, replicas and IRSA in one values file. `argocd-values.yaml` exposes the UI at `https://argocd.afriqhome.com` through an ALB with the ACM certificate (replace the domain with yours):

```yaml
global:
  domain: argocd.afriqhome.com
configs:
  params:
    server.insecure: true        # TLS ends at the ALB; ALB -> argocd-server is plain HTTP
server:
  ingress:
    enabled: true
    controller: aws
    ingressClassName: alb
    annotations:
      alb.ingress.kubernetes.io/scheme: internet-facing
      alb.ingress.kubernetes.io/target-type: ip
      alb.ingress.kubernetes.io/backend-protocol: HTTP
      alb.ingress.kubernetes.io/listen-ports: '[{"HTTP":80},{"HTTPS":443}]'
      alb.ingress.kubernetes.io/ssl-redirect: "443"
    aws:
      serviceType: ClusterIP
      backendProtocolVersion: GRPC
```

```bash
helm repo add argo https://argoproj.github.io/argo-helm
helm repo update
helm install argocd argo/argo-cd --version 10.10.5 \
  --namespace argocd --create-namespace \
  -f argocd-values.yaml --wait
```
Chart 10.10.5 installs Argo CD **v3.5.5**. Pin the chart version: upgrades become an explicit `helm upgrade`, not a surprise.

```bash
kubectl get pods -n argocd
# 7 pods Running: application-controller, applicationset-controller, dex-server,
# notifications-controller, redis, repo-server, server
kubectl get ingress -n argocd
kubectl logs -n external-dns deploy/external-dns | grep argocd
# wait for "CREATE argocd.afriqhome.com", then about 1 minute
```

**Alternative (no Helm):** `kubectl create namespace argocd && kubectl apply -n argocd --server-side -f https://raw.githubusercontent.com/argoproj/argo-cd/v3.5.5/manifests/install.yaml`. Use a version tag, never `stable`.

### IRSA for ArgoCD (optional, but production-grade on EKS)

ArgoCD itself usually does not need AWS API access — it talks to Git and the in-cluster Kubernetes API. But two real-world cases need IRSA:

1. **Git repo on AWS CodeCommit** — the `argocd-repo-server` ServiceAccount needs an IAM role allowing `codecommit:GitPull`.
2. **Helm charts in a private ECR registry** — the `argocd-repo-server` ServiceAccount needs `ecr:GetAuthorizationToken` and `ecr:BatchGetImage` on the relevant repos.

With the Helm chart, put the role on the repo-server ServiceAccount in the values file and `helm upgrade`:
```yaml
repoServer:
  serviceAccount:
    annotations:
      eks.amazonaws.com/role-arn: arn:aws:iam::<your-account-id>:role/ArgoCDRepoServerRole
```

---

## Access the UI

Open **https://argocd.afriqhome.com** (padlock: the ACM certificate). No domain? `kubectl port-forward svc/argocd-server -n argocd 8080:80` and open http://localhost:8080.

Username: `admin`. Get the initial password:

```bash
kubectl -n argocd get secret argocd-initial-admin-secret \
  -o jsonpath="{.data.password}" | base64 -d ; echo
```

Change this password after the first login (**User Info > Update password**), then delete the secret `argocd-initial-admin-secret`.

---

## The 3 concepts

ArgoCD's whole model is three CRDs:

- **Application** — a CRD that says "watch THIS Git repo, THIS path, sync to THIS namespace on THIS cluster." This is the main building block.
- **AppProject** — groups Applications for RBAC. "The platform team can deploy to any namespace; the payments team can only deploy to `payments-*`."
- **Sync policy** — lives on the Application. Two flavors:
  - **Manual** — you (or a CI job) click "Sync" in the UI (or run `argocd app sync`) to apply pending changes.
  - **Automated** — ArgoCD reconciles on every commit. With `selfHeal: true`, it also reverts manual edits. With `prune: true`, it deletes resources that are removed from Git.

## Sample Application manifest

`argocd-application.yaml` deploys the folder `22-argocd/demo-app/` of this repo (a Deployment `nginx-demo` with 2 replicas and a Service) into the `default` namespace, with automated sync, prune and self-heal.

```bash
kubectl apply -f argocd-application.yaml
kubectl get applications -n argocd
# nginx-demo   Synced   Healthy   (after about 10 seconds)
kubectl get deploy nginx-demo
```

Watch in the UI: `nginx-demo` appears, syncs, and becomes `Healthy / Synced`. Click it to see the tree: Application > Deployment > ReplicaSet > Pods.

## Test

1. **Drift detection + self-heal.** Change the cluster by hand: Git wins.
```bash
kubectl scale deployment nginx-demo --replicas=5
kubectl get deploy nginx-demo -w
# 5 ... then back to 2 within about 10 seconds: ArgoCD reverted the manual change (selfHeal: true)
```

2. **Git is the source of truth** (needs your fork). Change `replicas: 2` to `3` in `22-argocd/demo-app/deployment.yaml`, commit, push. Within ~3 minutes (the default poll interval) ArgoCD applies the change. Click **Refresh** in the UI to check immediately.

## App-of-Apps

`argocd-app-of-apps.yaml` creates a **root** Application that watches the folder `22-argocd/child-apps/`. That folder contains only **Application** manifests (`demo-dev.yaml`, `demo-prod.yaml`): the same `demo-app` deployed in the namespaces `demo-dev` and `demo-prod`. Add a file to `child-apps/`, commit, and a new application appears: nobody runs `kubectl apply` any more.
```bash
kubectl apply -f argocd-app-of-apps.yaml
kubectl get applications -n argocd
# root-app, demo-dev, demo-prod (plus nginx-demo): all Synced / Healthy
kubectl get deploy -n demo-dev
kubectl get deploy -n demo-prod
```

## AppProject

`argocd-appproject.yaml` creates the project `team-a`: its Applications may only come from the listed Git repos, may only deploy to the namespaces `team-a-dev` and `team-a-prod`, and cannot create cluster-wide resources.
```bash
kubectl apply -f argocd-appproject.yaml
kubectl get appproject -n argocd
```
An Application with `project: team-a` that targets another namespace is refused by ArgoCD (`namespace ... is not permitted in project 'team-a'`).

## Cleanup

Use the included `cleanup.sh`:

```bash
chmod +x cleanup.sh
./cleanup.sh
```

It deletes the Applications and the demo apps, the AppProject, uninstalls ArgoCD (which removes its ALB; ExternalDNS then deletes `argocd.afriqhome.com`), the namespaces and the ArgoCD CRDs.
