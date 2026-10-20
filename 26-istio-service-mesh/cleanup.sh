#!/usr/bin/env bash
cd "$(dirname "$0")"
kubectl delete -f 07-gateway-api-ingress.yaml --ignore-not-found
kubectl delete -f 06-authorization-policy.yaml --ignore-not-found
kubectl delete -f 05-mtls-strict.yaml --ignore-not-found
kubectl delete -f 02-destinationrule.yaml -f 03-virtualservice-canary.yaml --ignore-not-found
kubectl delete -f 01-namespace-and-apps.yaml --ignore-not-found
kubectl delete -f https://raw.githubusercontent.com/istio/istio/release-1.31/samples/addons/kiali.yaml --ignore-not-found
kubectl delete -f https://raw.githubusercontent.com/istio/istio/release-1.31/samples/addons/prometheus.yaml --ignore-not-found
istioctl uninstall --purge -y
kubectl delete namespace istio-system --ignore-not-found
