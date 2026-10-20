#!/usr/bin/env bash
# Install cert-manager with Helm (the method used in readme.md).
helm repo add jetstack https://charts.jetstack.io
helm repo update jetstack
helm install cert-manager jetstack/cert-manager \
  --namespace cert-manager --create-namespace \
  --version v1.21.2 \
  --set crds.enabled=true \
  --wait
kubectl get pods -n cert-manager
