# eks-full-infra

A complete, production-style EKS platform built with Terraform, and a GitOps self-service for app teams.

| What | Where |
|---|---|
| Terraform: VPC, EKS 1.36, add-ons, Pod Identity, Gateway API, AWS Load Balancer Controller, Istio, cert-manager, ExternalDNS, Argo CD, platform config | [`terraform/`](terraform/) |
| Guide for the platform team (architecture, create, operate, troubleshoot, destroy) | [`docs/platform-guide.md`](docs/platform-guide.md) |
| GitOps repository for app teams (app template chart, app requests `apps/<name>/<env>.yaml`, PR validation) and their guide | [utrains/platform-gitops](https://github.com/utrains/platform-gitops) |

Quick start:
```bash
cd terraform
cp terraform.tfvars.example terraform.tfvars   # set your domain (public Route 53 zone)
terraform init && terraform apply              # ~25 minutes
```
An app team then adds `apps/<name>/<env>.yaml` (image + port) in platform-gitops, and gets
`https://<name>-<env>.<domain>` with a Let's Encrypt certificate about 5 minutes after the merge.
