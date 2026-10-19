#!/usr/bin/env bash
# Run by "terraform destroy" (terraform_data.pre_destroy) BEFORE ArgoCD, ExternalDNS and the
# load balancer controller are uninstalled:
#   1. delete the ApplicationSet => ArgoCD deletes every app (pods, gateways, certificates, routes)
#   2. delete the ArgoCD route/gateway
#   3. wait until ExternalDNS removed all the Route 53 records it owns (TXT owner = cluster name)
# Usage: pre-destroy.sh <cluster> <region> <hosted-zone-id> <externaldns-owner-id>
set -uo pipefail
CLUSTER="$1"; REGION="$2"; ZONE_ID="$3"; OWNER="$4"

KCFG="$(mktemp)"
trap 'rm -f "$KCFG"' EXIT
aws eks update-kubeconfig --name "$CLUSTER" --region "$REGION" --kubeconfig "$KCFG" >/dev/null || exit 0
k() { kubectl --kubeconfig "$KCFG" "$@"; }

echo "[pre-destroy] deleting the ApplicationSet and the apps"
k delete applicationset apps -n argocd --ignore-not-found --wait=false
for i in $(seq 1 60); do
  n=$(k get applications -n argocd -l app.kubernetes.io/part-of=apps --no-headers 2>/dev/null | wc -l)
  [ "$n" -eq 0 ] && break
  sleep 5
done
echo "[pre-destroy] apps left: ${n:-0}"

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
