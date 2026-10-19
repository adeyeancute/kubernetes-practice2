**Note: This practice should be done in the EKS cluster** (it also works on Docker Desktop / Kind, except the LoadBalancer in step 7).

# Istio service mesh

## What is a service mesh?

In a microservices app, services call each other over the network all the time. Every team ends up re-coding the same things inside their apps: retries, timeouts, TLS between services, "who is allowed to call me", metrics for every call.

A **service mesh** moves those concerns **out of the application code and into the platform**. Your app just makes plain HTTP calls; the mesh handles the rest.

**Istio** is the most widely used service mesh (a CNCF graduated project, like Kubernetes itself).

## How Istio works

- **Data plane**: a small **Envoy proxy** runs next to every app container (a **sidecar** container injected into the pod). All traffic in and out of the pod goes through it.
- **Control plane**: **istiod** (one Deployment in `istio-system`) pushes the routing rules, security policies and certificates to every proxy.

```
  pod: client                      pod: web-v1
 +----------------------+         +----------------------+
 | curl  ->  envoy  ----+--mTLS---+->  envoy  ->  web    |
 +----------------------+         +----------------------+
              ^                               ^
              +-------- config + certs -------+
                          istiod
```

**Note:** Istio also has an **ambient mode** with no sidecars (a per-node proxy, `ztunnel`, plus optional per-namespace `waypoint` proxies). It uses less memory. Sidecar mode is still the most common in production and is the easiest to see and understand, so we use it here.

## What you get without changing app code

| Feature | Istio resource | Example in this chapter |
|---|---|---|
| Traffic splitting (canary, A/B) | `VirtualService` + `DestinationRule`, or Gateway API `HTTPRoute` | 90% v1 / 10% v2 |
| Timeouts, retries | `VirtualService` | 2s timeout, 2 retries |
| Fault injection (chaos testing) | `VirtualService` | add 3s delay to 50% of requests |
| Encryption between services (mTLS) | `PeerAuthentication` | STRICT mTLS in a namespace |
| Service-to-service authorization | `AuthorizationPolicy` | only `client` may call `web` |
| Ingress from outside the cluster | Gateway API `Gateway` (or Istio `Gateway`) | LoadBalancer in front of the mesh |
| Observability | built-in metrics + Kiali | traffic graph |

### Istio vs Ingress / Gateway API (chapter 07)

- **Ingress / Gateway API** handle **north-south** traffic: from outside users **into** the cluster.
- A **service mesh** handles **east-west** traffic: **between** services inside the cluster.
- Istio **implements** the Gateway API, so the same `Gateway` / `HTTPRoute` resources you used with the ALB in chapter 07 work with Istio (`gatewayClassName: istio`).

### When to use it (and when not)

- **Use it** when you have many services, need mTLS everywhere (compliance, zero trust), want canary releases without touching app code, or want uniform metrics for every call.
- **Skip it** for a handful of services: it adds a proxy to every pod (CPU, memory, latency) and many new resources to learn and debug.

## Practice

### Prerequisites

- A running cluster and `kubectl` access (chapter 00).
- Install **istioctl** (the Istio CLI):

```bash
# Mac / Linux (downloads into ./istio-<version>)
curl -L https://istio.io/downloadIstio | ISTIO_VERSION=1.31.2 sh -
export PATH="$PWD/istio-1.31.2/bin:$PATH"

# Windows: download istioctl-1.31.2-win.zip from https://github.com/istio/istio/releases,
# unzip it and put istioctl.exe on your PATH. Or with choco:
choco install istioctl
```
```bash
istioctl version --remote=false
```

### 1. Install Istio

Check that the cluster is ready, then install with the `default` profile (istiod + an ingress gateway):
```bash
istioctl x precheck
istioctl install --set profile=default -y
kubectl get pods -n istio-system
# expect: istiod-... and istio-ingressgateway-... Running
```

Install the Gateway API CRDs (skip if you already did it in chapter 07):
```bash
kubectl get crd gateways.gateway.networking.k8s.io || \
kubectl apply --server-side -f https://github.com/kubernetes-sigs/gateway-api/releases/download/v1.6.0/standard-install.yaml
```

### 2. Deploy two versions of an app inside the mesh

The manifest `01-namespace-and-apps.yaml` creates:
- the namespace `mesh-demo` with the label `istio-injection: enabled` (this is what turns the mesh on),
- `web-v1` and `web-v2` (a tiny HTTP server that answers "hello from v1" / "hello from v2"),
- one Service `web` that selects **both** versions,
- a `client` pod (curl) to send requests from inside the mesh.

```bash
kubectl apply -f 01-namespace-and-apps.yaml
kubectl get pods -n mesh-demo
# READY shows 2/2: your container + the injected istio-proxy (Envoy) sidecar
kubectl get pod -n mesh-demo -l app=web -o jsonpath='{.items[0].spec.initContainers[*].name}'; echo
# expect: istio-init istio-proxy
```
Since Kubernetes 1.29, Istio injects `istio-proxy` as a **native sidecar**: an init container with `restartPolicy: Always`, which starts **before** your app and keeps running next to it. That is why it is listed under `initContainers`, not `containers`. (`istio-init` sets up the iptables rules that redirect the pod traffic to Envoy, then exits.)
```bash
kubectl get pod -n mesh-demo -l app=web -o jsonpath='{.items[0].spec.initContainers[?(@.name=="istio-proxy")].restartPolicy}'; echo
# Always
```

Send 20 requests. With no rules, the Service spreads them roughly 50/50:
```bash
kubectl exec -n mesh-demo deploy/client -- sh -c 'for i in $(seq 1 20); do curl -s web; done' | sort | uniq -c
```

### 3. Canary release: 90% v1, 10% v2

A **DestinationRule** gives names (subsets) to the versions, using pod labels. A **VirtualService** then says how to route between them.

```yaml
# 03-virtualservice-canary.yaml (main part)
  http:
  - match:                      # testers with this header always get v2
    - headers:
        x-canary:
          exact: "true"
    route:
    - destination: {host: web, subset: v2}
  - route:                      # everyone else: 90 / 10
    - destination: {host: web, subset: v1}
      weight: 90
    - destination: {host: web, subset: v2}
      weight: 10
    timeout: 2s
    retries: {attempts: 2, perTryTimeout: 1s}
```
```bash
kubectl apply -f 02-destinationrule.yaml
kubectl apply -f 03-virtualservice-canary.yaml

# about 90 v1 / 10 v2
kubectl exec -n mesh-demo deploy/client -- sh -c 'for i in $(seq 1 100); do curl -s web; done' | sort | uniq -c

# header-based routing: always v2
kubectl exec -n mesh-demo deploy/client -- sh -c 'for i in $(seq 1 10); do curl -s -H "x-canary: true" web; done' | sort | uniq -c
```
Notice: both Deployments still have **1 replica each**. Kubernetes alone can only split traffic by **pod count**. Istio splits by **percentage**, independently of replicas. To finish the rollout, change the weights to `0 / 100` and apply again.

### 4. Fault injection (chaos testing)

What does your app do when a dependency gets slow? Istio can inject a delay without touching the code. `04-fault-injection.yaml` replaces the VirtualService `web` with one that delays 50% of requests by 3 seconds.
```bash
kubectl apply -f 04-fault-injection.yaml
kubectl exec -n mesh-demo deploy/client -- sh -c 'for i in 1 2 3 4 5 6; do curl -s -o /dev/null -w "%{http_code} %{time_total}s\n" web; done'
# about half of the requests take ~3s
```
Put the canary rules back:
```bash
kubectl apply -f 03-virtualservice-canary.yaml
```

### 5. Mutual TLS (mTLS)

Inside the mesh, Envoy already encrypts traffic between sidecars automatically (**PERMISSIVE** mode: it also still accepts plain text). **STRICT** mode rejects any client that is not in the mesh.

```bash
kubectl apply -f 05-mtls-strict.yaml
kubectl wait --for=condition=Ready pod/outsider -n no-mesh --timeout=60s

# From inside the mesh: works (the sidecars do mTLS for you)
kubectl exec -n mesh-demo deploy/client -- curl -s web

# From the no-mesh namespace (no sidecar, plain text): rejected
kubectl exec -n no-mesh outsider -- curl -s -m 5 web.mesh-demo
echo "exit code: $?"
# expect: "connection reset by peer" / exit code 56
```
Check which certificate identity a workload has:
```bash
istioctl proxy-config secret deploy/client -n mesh-demo
```

### 6. Authorization: who may call whom

mTLS gives every pod a cryptographic identity based on its **service account**: `cluster.local/ns/<namespace>/sa/<service-account>`. An **AuthorizationPolicy** uses that identity (not IP addresses) to allow or deny calls.

`06-authorization-policy.yaml` allows only the `client` service account to call `web`, and only with `GET`:
```bash
kubectl apply -f 06-authorization-policy.yaml

# GET from client: allowed (wait ~10 seconds after apply: the policy is pushed to every sidecar)
kubectl exec -n mesh-demo deploy/client -- curl -s web

# POST from client: denied by the policy
kubectl exec -n mesh-demo deploy/client -- curl -s -X POST web
# expect: RBAC: access denied
```
Once a workload has an `ALLOW` policy, anything that does not match a rule is denied.

### 7. Ingress with the Gateway API

Expose the app to the internet with a Gateway API `Gateway` managed by Istio. Istio sees the `Gateway`, then creates a gateway Deployment and a `LoadBalancer` Service for it (on EKS: an AWS load balancer).

**Prerequisites (chapter 07):** the AWS Load Balancer Controller (it builds the NLB from the annotations under `spec.infrastructure`), ExternalDNS (it creates `mesh.afriqhome.com` from the HTTPRoute `hostnames`) and the ACM wildcard certificate. Replace `afriqhome.com` with your domain in the file.

`07-gateway-api-ingress.yaml` creates the `Gateway`, an `HTTPRoute` with the same 90/10 split, and one Service per version (an `HTTPRoute` splits between **Services**, a `VirtualService` between **subsets**).
```bash
CERT_ARN=$(aws acm list-certificates --region us-east-1 --query "CertificateSummaryList[?DomainName=='*.afriqhome.com'].CertificateArn" --output text)
sed "s|<your-acm-certificate-arn>|$CERT_ARN|" 07-gateway-api-ingress.yaml | kubectl apply -f -
kubectl get gateway -n mesh-demo
# wait until PROGRAMMED is True and ADDRESS shows a hostname (1 to 3 minutes)
kubectl wait --for=condition=Programmed gateway/web-gateway -n mesh-demo --timeout=300s

kubectl logs -n external-dns deploy/external-dns | grep mesh.afriqhome.com
# wait for "CREATE mesh.afriqhome.com", then 1 to 3 minutes (DNS + the NLB becoming active)
for i in $(seq 1 20); do curl -s https://mesh.afriqhome.com/; echo; done | sort | uniq -c
# HTTPS: the NLB decrypts with the ACM certificate (*.afriqhome.com) and forwards plain HTTP to the gateway
```
Does this work with the AuthorizationPolicy from step 6? No: requests through the gateway come from the gateway's own identity (the ServiceAccount `web-gateway-istio`), which is not allowed. You get `RBAC: access denied` (HTTP 403). Allow it by adding the gateway's service account (`web-gateway-istio`) as a second principal:
```bash
kubectl patch authorizationpolicy web-allow-client -n mesh-demo --type=json \
  -p='[{"op":"add","path":"/spec/rules/0/from/0/source/principals/-","value":"cluster.local/ns/mesh-demo/sa/web-gateway-istio"}]'
for i in $(seq 1 20); do curl -s https://mesh.afriqhome.com/; echo; done | sort | uniq -c
# about 90% "hello from v1", 10% "hello from v2"
```

### 8. (Optional) See the mesh: Kiali

Kiali draws a live graph of who calls whom, with error rates and the mTLS padlock. It needs Prometheus.
```bash
kubectl apply -f https://raw.githubusercontent.com/istio/istio/release-1.31/samples/addons/prometheus.yaml
kubectl apply -f https://raw.githubusercontent.com/istio/istio/release-1.31/samples/addons/kiali.yaml
kubectl rollout status deploy/kiali -n istio-system --timeout=180s

# generate some traffic, then open the dashboard (http://localhost:20001)
kubectl exec -n mesh-demo deploy/client -- sh -c 'for i in $(seq 1 200); do curl -s web >/dev/null; sleep 0.2; done' &
istioctl dashboard kiali
```
In Kiali: **Traffic Graph**, namespace `mesh-demo`, display **Traffic Distribution** and **Security**.

### Useful istioctl commands

| Command | What it does |
|---|---|
| `istioctl analyze -n mesh-demo` | Find mistakes in your Istio config (wrong host names, missing subsets...) |
| `istioctl proxy-status` | Is every sidecar in sync with istiod? |
| `istioctl proxy-config routes deploy/client -n mesh-demo` | The routes that one Envoy actually received |
| `kubectl label ns <ns> istio-injection=enabled` | Turn on the mesh for a namespace (restart pods afterwards) |
| `kubectl rollout restart deploy -n <ns>` | Re-create pods so they get (or lose) the sidecar |

## Cleanup

```bash
kubectl delete -f 07-gateway-api-ingress.yaml --ignore-not-found   # deletes the AWS load balancer
kubectl delete -f 06-authorization-policy.yaml --ignore-not-found
kubectl delete -f 05-mtls-strict.yaml --ignore-not-found
kubectl delete -f 02-destinationrule.yaml -f 03-virtualservice-canary.yaml --ignore-not-found
kubectl delete -f 01-namespace-and-apps.yaml --ignore-not-found

# Optional addons
kubectl delete -f https://raw.githubusercontent.com/istio/istio/release-1.31/samples/addons/kiali.yaml --ignore-not-found
kubectl delete -f https://raw.githubusercontent.com/istio/istio/release-1.31/samples/addons/prometheus.yaml --ignore-not-found

# Remove Istio itself (also removes the istio-ingressgateway load balancer)
istioctl uninstall --purge -y
kubectl delete namespace istio-system --ignore-not-found
```
Or simply run `./cleanup.sh`.
