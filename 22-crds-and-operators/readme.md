# CRDs and Operators

## What is a CRD?

A **CustomResourceDefinition** (CRD) is a way to teach Kubernetes a brand-new resource type. Kubernetes ships with built-ins like `Pod`, `Deployment`, `Service`, and `Job`. **CRDs let you add your own** — so the API server learns to accept `Certificate`, `PostgresCluster`, `KafkaTopic`, `Greeting`, or any kind you can dream up.

A CRD by itself is just a schema. It teaches `kubectl` what fields are allowed. It does **not** do anything when you create one of those resources.

## What is an Operator?

An **Operator** is a controller (a piece of code, almost always written in Go) that **watches a CRD and reconciles state**. When you `kubectl apply -f my-certificate.yaml`, the Operator notices the new `Certificate` object and does the actual work — calls Let's Encrypt, stores the cert in a Secret, sets up renewal.

> **CRD = the schema. Operator = the brains.**

## A brief history

The Operator pattern was named and popularized by CoreOS in **2016** with a blog post titled "Introducing Operators". The CRD machinery itself shipped a year earlier as `ThirdPartyResource` (deprecated) and was renamed `CustomResourceDefinition` in K8s 1.7 (2017). The CNCF Operator Framework (Operator SDK, OLM) followed in 2018, donated by Red Hat after the CoreOS acquisition. Today, the Operator pattern is how every non-trivial stateful workload — databases, message brokers, service meshes, certs, secrets — gets managed on Kubernetes.

## Why it matters

An Operator is the only realistic way to package "day-2 ops knowledge" (failover, backups, certificate rotation, version upgrades) as code that runs inside the cluster. Without one, every team rebuilds the same runbooks in Bash.

## Real-world Operators every DevOps engineer sees in 2026

| Operator | What it manages |
|---|---|
| **cert-manager** | TLS certificate lifecycle from Let's Encrypt / ACME / ACM Private CA |
| **postgres-operator** (CloudNativePG, Zalando, Crunchy) | PostgreSQL clusters with backups, failover, read replicas |
| **prometheus-operator** | Prometheus + Alertmanager + ServiceMonitor / PodMonitor ecosystem |
| **external-secrets-operator** | Sync secrets from AWS Secrets Manager / Vault / GCP Secret Manager into K8s Secrets |
| **argocd** (you saw it in chapter 21) | GitOps Application + AppProject |
| **istio / linkerd** | Service mesh resources (`VirtualService`, `DestinationRule`) |

## When to use vs not use an Operator

- **Use one** for any stateful workload (databases, queues, certs, secrets) where rolling your own runbooks is a tax you do not want to pay.
- **Skip it** for stateless apps you can express with a plain `Deployment` + `Service`. Adding a custom Operator just to deploy nginx is over-engineering.

---

## Practice: install cert-manager and use it

cert-manager is the canonical "first Operator everyone installs." We will install it, define a self-signed `Issuer`, request a `Certificate`, and watch cert-manager produce the backing Secret automatically.

### Prerequisites

- The EKS cluster `my-cluster` from chapter 00 (any cluster works: this chapter needs no AWS add-on).
- `kubectl` and `helm` installed locally.

### 1. Install cert-manager via Helm (officially recommended method)

cert-manager's documentation has, for several release cycles, recommended **Helm as the primary install method** for production use — the static `cert-manager.yaml` manifest is still published, but Helm gives you proper upgrade semantics and per-component tuning. We will use Helm here.

```bash
helm repo add jetstack https://charts.jetstack.io
helm repo update

# Pin to a specific version (latest: https://github.com/cert-manager/cert-manager/releases)
helm install cert-manager jetstack/cert-manager \
  --namespace cert-manager --create-namespace \
  --version v1.21.2 \
  --set crds.enabled=true \
  --wait
```

> Notes on the flags:
> - `--set crds.enabled=true` installs the cert-manager CRDs as part of the chart. In older versions (before 1.15) this flag was `--set installCRDs=true`; the current name is `crds.enabled`.
> - You can alternatively install CRDs separately with `kubectl apply -f https://github.com/cert-manager/cert-manager/releases/download/<VERSION>/cert-manager.crds.yaml` and then install the chart with `--set crds.enabled=false`.

### 2. Verify

```bash
kubectl get pods -n cert-manager
# expect three pods: cert-manager, cert-manager-cainjector, cert-manager-webhook
kubectl get crds | grep cert-manager
# expect: certificaterequests, certificates, challenges, clusterissuers, issuers, orders
```

### 3. Define a self-signed ClusterIssuer

```bash
kubectl apply -f selfsigned-issuer.yaml
kubectl get clusterissuer
```

### 4. Request a Certificate

```bash
kubectl apply -f demo-certificate.yaml
kubectl get certificate
kubectl describe certificate demo-tls
```

Within a few seconds, cert-manager creates a Secret named `demo-tls` containing `tls.crt` and `tls.key`:

```bash
kubectl get secret demo-tls -o yaml
```

You never wrote that Secret. The Operator did, because you asked for a Certificate.

## Anatomy of a CRD - the `Greeting` example

`custom-crd-greeting.yaml` defines a tiny custom resource called `Greeting`:

```bash
kubectl apply -f custom-crd-greeting.yaml
kubectl get crds | grep greetings
```

Now the API server understands `kind: Greeting`. You can create one:

```yaml
apiVersion: demo.utrains.io/v1
kind: Greeting
metadata:
  name: hello-world
spec:
  message: "Hello, class!"
  language: "en"
```

It is in `greeting-instance.yaml`, together with a second Greeting that has no `message`:
```bash
kubectl apply -f greeting-instance.yaml
# greeting.demo.utrains.io/hello-world created
# The Greeting "no-message" is invalid: spec.message: Required value   <- the CRD schema is enforced
kubectl get greetings
kubectl get gr                    # the short name from the CRD
kubectl get gr hello-world -o yaml
```

But **nothing happens** when you apply it — because we never wrote a controller. The object just sits in etcd. That's the point: **a CRD without an Operator is just a schema**.

## How to recognize an Operator in the wild

When you land in a new cluster and see:

```bash
kubectl get all -A
```

...look for:

1. **`kind: <SomethingYouNeverHeardOf>`** in YAML files (e.g., `kind: PostgresCluster`). That tells you a CRD is involved.
2. **A controller deployment in some `*-system` namespace**: `cert-manager`, `prometheus-operator`, `cnpg-system`, `argocd`, `external-secrets`. That's the Operator running.
3. Use `kubectl api-resources --api-group=<group>` to list every kind a given Operator added.

Once you can read an Operator's CRDs + controller deployment, you understand 90% of what it does. The rest is reading its docs.

## Cleanup

```bash
chmod +x cleanup.sh
./cleanup.sh
```

This removes the demo Greeting and Certificate, the ClusterIssuer, the `greetings` CRD, and uninstalls cert-manager (Helm release, namespace and CRDs).
