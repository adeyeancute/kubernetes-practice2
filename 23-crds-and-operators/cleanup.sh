#!/usr/bin/env bash
cd "$(dirname "$0")"
kubectl delete -f greeting-instance.yaml --ignore-not-found
kubectl delete crd greetings.demo.utrains.io --ignore-not-found
kubectl delete certificate demo-tls --ignore-not-found
kubectl delete secret demo-tls --ignore-not-found
kubectl delete clusterissuer selfsigned-issuer --ignore-not-found
helm uninstall cert-manager -n cert-manager
kubectl delete namespace cert-manager --ignore-not-found
# the chart keeps its CRDs (crds.keep=true by default): remove them when you are done
kubectl get crd -o name | grep cert-manager.io | xargs -r kubectl delete
