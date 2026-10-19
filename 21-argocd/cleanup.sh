#!/usr/bin/env bash
cd "$(dirname "$0")"
# Applications first, then the resources they created (the demo Applications have no deletion finalizer)
kubectl delete -f argocd-app-of-apps.yaml --ignore-not-found
kubectl delete application demo-dev demo-prod nginx-demo -n argocd --ignore-not-found
kubectl delete deployment,service nginx-demo -n default --ignore-not-found
kubectl delete namespace demo-dev demo-prod --ignore-not-found
kubectl delete -f argocd-appproject.yaml --ignore-not-found
# ArgoCD itself (also deletes its ALB; ExternalDNS removes the DNS record)
helm uninstall argocd -n argocd
kubectl delete namespace argocd --ignore-not-found
# helm keeps the ArgoCD CRDs: remove them when you are done with ArgoCD
kubectl get crd -o name | grep argoproj.io | xargs -r kubectl delete
