#!/usr/bin/env bash
# Run by "terraform destroy" (terraform_data.pre_destroy) BEFORE ArgoCD, ExternalDNS and the
# load balancer controller are uninstalled:
#   1. delete the ApplicationSets "apps" and "teams" and the Application "platform-addons"
#      => ArgoCD deletes every app, team namespace and add-on (pods, gateways, certificates, routes)
#   2. delete the volumes left behind (StatefulSet PVCs) => the EBS volumes / EFS access points go
#   3. delete the ArgoCD route/gateway
#   4. wait until ExternalDNS removed all the Route 53 records it owns (TXT owner = cluster name)
# Usage: pre-destroy.sh <cluster> <region> <hosted-zone-id> <externaldns-owner-id>
set -uo pipefail
CLUSTER="$1"; REGION="$2"; ZONE_ID="$3"; OWNER="$4"

KCFG="$(mktemp)"
trap 'rm -f "$KCFG"' EXIT
aws eks update-kubeconfig --name "$CLUSTER" --region "$REGION" --kubeconfig "$KCFG" >/dev/null || exit 0
k() { kubectl --kubeconfig "$KCFG" "$@"; }

echo "[pre-destroy] deleting the apps, the team namespaces and the platform add-ons"
k delete applicationset apps teams -n argocd --ignore-not-found --wait=false
k delete application platform-addons -n argocd --ignore-not-found --wait=false
for i in $(seq 1 120); do
  n=$(k get applications -n argocd --no-headers 2>/dev/null | wc -l)
  [ "$n" -eq 0 ] && break
  sleep 5
done
echo "[pre-destroy] Argo CD applications left: ${n:-0}"
if [ "${n:-0}" -gt 0 ]; then
  k get applications -n argocd -o custom-columns=NAME:.metadata.name,SYNC:.status.sync.status,HEALTH:.status.health.status,PHASE:.status.operationState.phase --no-headers | sed 's/^/[pre-destroy]   still there: /'
fi

# A volume is only deleted once no pod uses it. Stop every workload that still holds a volume
# (whatever Argo CD did not finish deleting), then delete the claims: the EBS CSI driver deletes the
# EBS volumes and the EFS CSI driver the access points. Without this, the volumes outlive the cluster.
echo "[pre-destroy] deleting the remaining volumes (EBS volumes, EFS access points)"
for ns in $(k get pvc -A --no-headers 2>/dev/null | awk '{print $1}' | sort -u); do
  echo "[pre-destroy]   stopping the workloads of namespace $ns"
  k delete statefulset,deployment,daemonset,job --all -n "$ns" --ignore-not-found --wait=false
  k delete prometheus --all -n "$ns" --ignore-not-found --wait=false 2>/dev/null
done
k delete pvc --all -A --ignore-not-found --wait=false
for i in $(seq 1 90); do
  pv=$(k get pv --no-headers 2>/dev/null | wc -l)
  [ "$pv" -eq 0 ] && break
  sleep 5
done
echo "[pre-destroy] persistent volumes left: ${pv:-0}"
if [ "${pv:-0}" -gt 0 ]; then
  echo "[pre-destroy] WARNING: these volumes may outlive the cluster, delete them after the destroy:"
  k get pv -o custom-columns=PV:.metadata.name,CLAIM:.spec.claimRef.name,VOLUME:.spec.csi.volumeHandle --no-headers | sed 's/^/[pre-destroy]   /'
fi

echo "[pre-destroy] deleting the ArgoCD routes"
k delete httproute argocd argocd-redirect -n argocd --ignore-not-found

echo "[pre-destroy] waiting for ExternalDNS to delete its Route 53 records (owner=$OWNER)"
for i in $(seq 1 30); do
  left=$(aws route53 list-resource-record-sets --hosted-zone-id "$ZONE_ID" \
    --query "length(ResourceRecordSets[?Type=='TXT' && contains(join('',ResourceRecords[].Value), 'external-dns/owner=$OWNER')])" --output text)
  [ "$left" = "0" ] && break
  sleep 10
done
echo "[pre-destroy] ExternalDNS records left: $left"
exit 0
