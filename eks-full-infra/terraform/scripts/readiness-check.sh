#!/usr/bin/env bash
# Readiness check of the platform, without deploying a real application.
# Proves each required outcome with a test, prints PASS/FAIL per check, cleans up after itself.
#   Usage (from eks-full-infra/terraform, after terraform apply):  bash scripts/readiness-check.sh
#   Needs: terraform outputs, aws, kubectl, curl.
set -uo pipefail
export MSYS_NO_PATHCONV=1   # Git Bash on Windows: do not rewrite /data/... arguments into C:/Program Files/Git/...
cd "$(dirname "$0")/.."

CLUSTER=$(terraform output -raw cluster_name)
REGION=$(sed -n 's/^region *= *"\(.*\)".*/\1/p' terraform.tfvars); REGION=${REGION:-us-east-1}
DOMAIN=$(sed -n 's/^domain *= *"\([^"]*\)".*/\1/p' terraform.tfvars)
GRAFANA_URL=$(terraform output -raw grafana_url)
aws eks update-kubeconfig --name "$CLUSTER" --region "$REGION" >/dev/null

pass=0; failed=0
ok()   { echo "PASS  $*"; pass=$((pass + 1)); }
ko()   { echo "FAIL  $*"; failed=$((failed + 1)); }
check() { local name="$1"; shift; if "$@" >/dev/null 2>&1; then ok "$name"; else ko "$name"; fi; }
section() { echo; echo "== $* =="; }
retry() { local n=$1; shift; for _ in $(seq 1 "$n"); do "$@" >/dev/null 2>&1 && return 0; sleep 10; done; return 1; }

T=readiness-check          # scratch namespace for the storage test
TEAM_NS=payments-dev       # team namespaces used for the isolation tests (from teams/ in platform-gitops)
OTHER_NS=search-dev
PROD_NS=payments-prod

cleanup() {
  kubectl delete namespace "$T" --ignore-not-found --wait=false >/dev/null 2>&1
  kubectl -n "$TEAM_NS" delete deployment,service,httproute -l readiness-check=true --ignore-not-found >/dev/null 2>&1
  kubectl -n "$TEAM_NS" delete pod curl --ignore-not-found --wait=false >/dev/null 2>&1
  kubectl -n "$OTHER_NS" delete pod curl --ignore-not-found --wait=false >/dev/null 2>&1
}
trap cleanup EXIT

# ---------------------------------------------------------------------------------------------
section "1. Cluster and add-ons (built by terraform)"
nodes=$(kubectl get nodes --no-headers | grep -c " Ready")
[ "$nodes" -ge 2 ] && ok "$nodes nodes Ready" || ko "nodes Ready: $nodes"
for a in $(aws eks list-addons --cluster-name "$CLUSTER" --region "$REGION" --query 'addons[]' --output text); do
  s=$(aws eks describe-addon --cluster-name "$CLUSTER" --region "$REGION" --addon-name "$a" --query addon.status --output text)
  [ "$s" = "ACTIVE" ] && ok "EKS add-on $a ACTIVE" || ko "EKS add-on $a: $s"
done
for d in kube-system/aws-load-balancer-controller cert-manager/cert-manager external-dns/external-dns istio-system/istiod istio-ingress/istio-ingress argocd/argocd-server; do
  check "Deployment $d available" kubectl -n "${d%%/*}" rollout status deployment "${d##*/}" --timeout=60s
done

# ---------------------------------------------------------------------------------------------
section "2. GitOps: Argo CD manages the platform add-ons and the teams from Git"
for app in platform-addons kube-prometheus-stack loki fluent-bit team-payments team-search; do
  st=$(kubectl -n argocd get application "$app" -o jsonpath='{.status.sync.status}/{.status.health.status}' 2>/dev/null)
  [ "$st" = "Synced/Healthy" ] && ok "Argo CD application $app Synced/Healthy" || ko "Argo CD application $app: ${st:-missing}"
done

# ---------------------------------------------------------------------------------------------
section "3. Storage: EBS and EFS StorageClasses, one EFS volume mounted by two pods at once"
check "StorageClass gp3 (EBS) exists and is the default" bash -c "kubectl get sc gp3 -o jsonpath='{.metadata.annotations.storageclass\.kubernetes\.io/is-default-class}' | grep -q true"
check "StorageClass efs (EFS) exists" kubectl get sc efs
kubectl create namespace "$T" >/dev/null 2>&1
kubectl apply -f - >/dev/null <<EOF
apiVersion: v1
kind: PersistentVolumeClaim
metadata: {name: shared, namespace: $T}
spec:
  accessModes: [ReadWriteMany]
  storageClassName: efs
  resources: {requests: {storage: 1Gi}}
---
apiVersion: apps/v1
kind: Deployment
metadata: {name: efs-pods, namespace: $T}
spec:
  replicas: 2
  selector: {matchLabels: {app: efs-pods}}
  template:
    metadata: {labels: {app: efs-pods}}
    spec:
      affinity:
        podAntiAffinity:            # the two pods MUST run on different nodes
          requiredDuringSchedulingIgnoredDuringExecution:
            - labelSelector: {matchLabels: {app: efs-pods}}
              topologyKey: kubernetes.io/hostname
      containers:
        - name: c
          image: busybox:1.36
          command: [sh, -c, "sleep 3600"]
          volumeMounts: [{name: data, mountPath: /data}]
      volumes:
        - name: data
          persistentVolumeClaim: {claimName: shared}
EOF
if kubectl -n "$T" rollout status deployment efs-pods --timeout=300s >/dev/null 2>&1; then
  mapfile -t P < <(kubectl -n "$T" get pods -l app=efs-pods -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}')
  n1=$(kubectl -n "$T" get pod "${P[0]}" -o jsonpath='{.spec.nodeName}'); n2=$(kubectl -n "$T" get pod "${P[1]}" -o jsonpath='{.spec.nodeName}')
  kubectl -n "$T" exec "${P[0]}" -- sh -c "echo written-by-${P[0]} > /data/proof.txt"
  got=$(kubectl -n "$T" exec "${P[1]}" -- cat /data/proof.txt 2>/dev/null)
  [ "$got" = "written-by-${P[0]}" ] && [ "$n1" != "$n2" ] \
    && ok "EFS volume shared: pod on $n1 wrote, pod on $n2 read it back" \
    || ko "EFS shared volume (read '$got', nodes $n1 / $n2)"
else
  ko "EFS test pods did not start (kubectl -n $T describe pvc shared)"
fi

# ---------------------------------------------------------------------------------------------
section "4. Multi-tenancy: namespaces, RBAC, ResourceQuota, NetworkPolicies"
for ns in "$TEAM_NS" "$PROD_NS" "$OTHER_NS"; do
  check "namespace $ns has a ResourceQuota, a LimitRange and a default-deny NetworkPolicy" \
    bash -c "kubectl -n $ns get resourcequota -o name | grep -q . && kubectl -n $ns get limitrange -o name | grep -q . && kubectl -n $ns get networkpolicy default-deny-ingress"
done
can() { kubectl auth can-i "$1" "$2" -n "$3" --as=alice --as-group="$4" 2>/dev/null; }
[ "$(can create deployments $TEAM_NS payments-developers)" = yes ] && ok "RBAC: payments developer can deploy in $TEAM_NS" || ko "RBAC: payments developer cannot deploy in $TEAM_NS"
[ "$(can create httproutes $TEAM_NS payments-developers)" = yes ] && ok "RBAC: payments developer can publish an HTTPRoute in $TEAM_NS" || ko "RBAC: HTTPRoute in $TEAM_NS"
[ "$(can create deployments $PROD_NS payments-developers)" = no ] && ok "RBAC: payments developer is read-only in $PROD_NS" || ko "RBAC: payments developer can write in $PROD_NS"
[ "$(can get pods $OTHER_NS payments-developers)" = no ] && ok "RBAC: payments developer cannot see $OTHER_NS" || ko "RBAC: payments developer can see $OTHER_NS"
[ "$(can get secrets kube-system payments-admins)" = no ] && ok "RBAC: payments admin has no access to kube-system" || ko "RBAC: payments admin can read kube-system"
lb_out=$(kubectl -n "$TEAM_NS" create service loadbalancer sneaky-lb --tcp=80:80 2>&1)
if [[ "$lb_out" == *"exceeded quota"* ]]; then
  ok "Quota: a LoadBalancer Service (= a new load balancer) is refused in $TEAM_NS"
else
  ko "Quota: a LoadBalancer Service was accepted in $TEAM_NS"; kubectl -n "$TEAM_NS" delete service sneaky-lb --ignore-not-found >/dev/null
fi

# a test service in payments-dev, published on the shared load balancer
kubectl apply -f - >/dev/null <<EOF
apiVersion: apps/v1
kind: Deployment
metadata: {name: echo, namespace: $TEAM_NS, labels: {readiness-check: "true"}}
spec:
  replicas: 1
  selector: {matchLabels: {app: echo}}
  template:
    metadata: {labels: {app: echo}}
    spec:
      containers:
        - name: echo
          image: traefik/whoami:v1.11.0
          ports: [{containerPort: 80}]
          readinessProbe: {httpGet: {path: /, port: 80}}
---
apiVersion: v1
kind: Service
metadata: {name: echo, namespace: $TEAM_NS, labels: {readiness-check: "true"}}
spec:
  selector: {app: echo}
  ports: [{port: 80, targetPort: 80}]
---
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata: {name: echo, namespace: $TEAM_NS, labels: {readiness-check: "true"}}
spec:
  parentRefs: [{name: $TEAM_NS, namespace: istio-ingress, sectionName: https}]
  hostnames: [echo.$TEAM_NS.$DOMAIN]
  rules: [{backendRefs: [{name: echo, port: 80}]}]
EOF
for ns in "$TEAM_NS" "$OTHER_NS"; do
  kubectl -n "$ns" run curl --image=curlimages/curl:8.11.1 --restart=Never --command -- sleep 3600 >/dev/null 2>&1
done
kubectl -n "$TEAM_NS" rollout status deployment echo --timeout=180s >/dev/null 2>&1 \
  && ok "pod with a readiness probe becomes Ready in $TEAM_NS (probes pass the NetworkPolicies)" || ko "echo pod not Ready in $TEAM_NS"
kubectl -n "$TEAM_NS" wait pod curl --for=condition=Ready --timeout=120s >/dev/null 2>&1
kubectl -n "$OTHER_NS" wait pod curl --for=condition=Ready --timeout=120s >/dev/null 2>&1
code() { kubectl -n "$1" exec curl -c curl -- curl -s -o /dev/null -m 5 -w '%{http_code}' "http://echo.$TEAM_NS.svc.cluster.local/" 2>/dev/null; }
c=$(code "$TEAM_NS"); [ "$c" = 200 ] && ok "NetworkPolicy: same namespace reaches echo (HTTP $c)" || ko "NetworkPolicy: same namespace got '$c'"
c=$(code "$OTHER_NS"); [ "$c" != 200 ] && ok "NetworkPolicy: $OTHER_NS is blocked from $TEAM_NS (got '${c:-timeout}')" || ko "NetworkPolicy: $OTHER_NS reached $TEAM_NS"

# ---------------------------------------------------------------------------------------------
section "5. Ingress: one shared load balancer serves many teams (Gateway API)"
lbs=$(aws elbv2 describe-load-balancers --region "$REGION" --query 'LoadBalancers[].LoadBalancerArn' --output text | tr '\t' '\n' | grep . |
  while read -r arn; do aws elbv2 describe-tags --region "$REGION" --resource-arns "$arn" --query "TagDescriptions[].Tags[?Key=='elbv2.k8s.aws/cluster'].Value" --output text; done | grep -cx "$CLUSTER")
gws=$(kubectl -n istio-ingress get gateway --no-headers | wc -l)
[ "$lbs" -eq 1 ] && ok "1 AWS load balancer for $gws Gateways (apps, teams, Argo CD, Grafana)" || ko "$lbs load balancers for the cluster"
url="https://echo.$TEAM_NS.$DOMAIN/"
retry 30 bash -c "curl -sf -o /dev/null -m 10 '$url'" \
  && ok "team service published through the shared gateway: $url (trusted certificate, DNS by ExternalDNS)" || ko "$url not reachable"

# ---------------------------------------------------------------------------------------------
section "6. Observability: metrics and logs per namespace"
for d in monitoring/grafana monitoring/kube-prometheus-stack-operator monitoring/kube-prometheus-stack-kube-state-metrics; do
  check "Deployment $d available" kubectl -n "${d%%/*}" rollout status deployment "${d##*/}" --timeout=60s
done
check "Prometheus running" kubectl -n monitoring rollout status statefulset prometheus-kube-prometheus-stack-prometheus --timeout=60s
check "Loki running" kubectl -n monitoring rollout status statefulset loki --timeout=60s
check "Fluent Bit on every node" kubectl -n monitoring rollout status daemonset fluent-bit --timeout=60s
retry 18 bash -c "curl -sf -m 10 '$GRAFANA_URL/api/health'" && ok "Grafana UI: $GRAFANA_URL" || ko "Grafana not reachable at $GRAFANA_URL"
PW=$(kubectl -n monitoring get secret grafana -o jsonpath='{.data.admin-password}' | base64 -d)
promql="sum by (namespace) (container_memory_working_set_bytes{namespace=\"$TEAM_NS\"})"
has_metrics() {
  curl -sf -m 20 -u "admin:$PW" -G "$GRAFANA_URL/api/datasources/proxy/uid/prometheus/api/v1/query" \
    --data-urlencode "query=$promql" | grep -q "\"namespace\":\"$TEAM_NS\""
}
retry 12 has_metrics \
  && ok "metrics: Prometheus (through Grafana) has memory usage for namespace $TEAM_NS" || ko "no metrics for namespace $TEAM_NS"
retry 18 bash -c "curl -sf -m 20 -u admin:'$PW' '$GRAFANA_URL/api/datasources/proxy/uid/loki/loki/api/v1/label/namespace/values' | grep -q '\"$TEAM_NS\"'" \
  && ok "logs: Loki (through Grafana) has logs labelled namespace=$TEAM_NS" || ko "no logs for namespace $TEAM_NS in Loki"

# ---------------------------------------------------------------------------------------------
echo
echo "== $pass passed, $failed failed =="
[ "$failed" -eq 0 ]
