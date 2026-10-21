output "cluster_name" {
  value = module.eks.cluster_name
}

output "configure_kubectl" {
  description = "Command to point kubectl at the new cluster"
  value       = "aws eks update-kubeconfig --name ${module.eks.cluster_name} --region ${var.region}"
}

output "argocd_url" {
  value = "https://${var.argocd_subdomain}.${var.domain}"
}

output "argocd_admin_password_command" {
  value = "kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d; echo"
}

output "ingress_load_balancer" {
  description = "DNS name of the NLB in front of the shared Istio ingress gateway"
  value       = data.kubernetes_service_v1.istio_ingress.status[0].load_balancer[0].ingress[0].hostname
}

output "app_url_pattern" {
  value = "https://<name>-<env>.${var.domain}  (env=prod: https://<name>.${var.domain})"
}

output "grafana_url" {
  value = "https://${var.grafana_subdomain}.${var.domain}"
}

output "grafana_admin_password_command" {
  value = "kubectl -n monitoring get secret grafana -o jsonpath='{.data.admin-password}' | base64 -d; echo"
}

output "team_url_pattern" {
  value = "https://<service>.<team>-<env>.${var.domain}  (env=prod: https://<service>.<team>.${var.domain})"
}
