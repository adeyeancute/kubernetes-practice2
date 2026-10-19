# Platform components, installed with Helm in dependency order.
#
#   gateway-api-crds ─┬─> aws-load-balancer-controller ─┐
#                     └─> istio-base ─> istiod ─────────┴─> istio-ingress (shared gateway, 1 NLB)
#   cert-manager, external-dns, argo-cd ───────────────────> platform-config (issuers, ArgoCD URL,
#                                                              ApplicationSet that deploys apps/)

locals {
  ingress_namespace   = "istio-ingress"
  ingress_name        = "istio-ingress"
  ingress_service_dns = "${local.ingress_name}.${local.ingress_namespace}.svc.cluster.local"
}

# --- Gateway API CRDs (v1.6.0 standard channel, vendored in charts/gateway-api-crds) ---
resource "helm_release" "gateway_api_crds" {
  name      = "gateway-api-crds"
  chart     = "${path.module}/charts/gateway-api-crds"
  namespace = "kube-system"

  depends_on = [module.eks]
}

# --- AWS Load Balancer Controller: builds the NLB in front of the Istio ingress gateway ---
resource "helm_release" "aws_load_balancer_controller" {
  name       = "aws-load-balancer-controller"
  repository = "https://aws.github.io/eks-charts"
  chart      = "aws-load-balancer-controller"
  version    = var.versions.aws_load_balancer_controller
  namespace  = "kube-system"
  wait       = true

  values = [yamlencode({
    clusterName = module.eks.cluster_name
    region      = var.region
    vpcId       = module.vpc.vpc_id
    serviceAccount = {
      create = true
      name   = "aws-load-balancer-controller"
    }
    # only handle Services that ask for it (annotation aws-load-balancer-type: external)
    enableServiceMutatorWebhook = false
  })]

  depends_on = [module.aws_lb_controller_pod_identity, helm_release.gateway_api_crds, module.vpc]
}

# --- cert-manager: Let's Encrypt certificates (DNS-01 in Route 53) for every app ---
resource "helm_release" "cert_manager" {
  name             = "cert-manager"
  repository       = "https://charts.jetstack.io"
  chart            = "cert-manager"
  version          = var.versions.cert_manager
  namespace        = "cert-manager"
  create_namespace = true
  wait             = true

  values = [yamlencode({
    crds           = { enabled = true }
    serviceAccount = { name = "cert-manager" }
    # delete the TLS Secret when its Certificate is deleted (removed apps leave nothing behind)
    enableCertificateOwnerRef = true
  })]

  depends_on = [module.cert_manager_pod_identity, module.eks, module.vpc]
}

# --- ExternalDNS: one Route 53 record per HTTPRoute hostname ---
resource "helm_release" "external_dns" {
  name             = "external-dns"
  repository       = "https://kubernetes-sigs.github.io/external-dns/"
  chart            = "external-dns"
  version          = var.versions.external_dns
  namespace        = "external-dns"
  create_namespace = true
  wait             = true

  values = [yamlencode({
    provider       = { name = "aws" }
    env            = [{ name = "AWS_DEFAULT_REGION", value = var.region }]
    serviceAccount = { create = true, name = "external-dns" }
    sources        = ["gateway-httproute"]
    domainFilters  = [var.domain]
    policy         = "sync"           # also deletes the records it created when an app goes away
    registry       = "txt"            # TXT ownership records: never touches records it did not create
    txtOwnerId     = var.cluster_name # unique per cluster
    txtPrefix      = "extdns-"
    interval       = "30s"
  })]

  depends_on = [module.external_dns_pod_identity, helm_release.gateway_api_crds, module.vpc]
}

# --- Istio (sidecar mode): base CRDs, control plane, shared ingress gateway ---
resource "helm_release" "istio_base" {
  name             = "istio-base"
  repository       = "https://istio-release.storage.googleapis.com/charts"
  chart            = "base"
  version          = var.versions.istio
  namespace        = "istio-system"
  create_namespace = true

  depends_on = [helm_release.gateway_api_crds]
}

resource "helm_release" "istiod" {
  name       = "istiod"
  repository = "https://istio-release.storage.googleapis.com/charts"
  chart      = "istiod"
  version    = var.versions.istio
  namespace  = "istio-system"
  wait       = true

  values = [yamlencode({
    pilot = {
      resources = { requests = { cpu = "100m", memory = "256Mi" } }
    }
    meshConfig = {
      accessLogFile = "/dev/stdout" # gateway and sidecar access logs, handy when debugging an app
    }
  })]

  depends_on = [helm_release.istio_base]
}

# One gateway Deployment + one LoadBalancer Service (= one NLB) shared by every app.
# Each app has its own Gateway resource bound to this Service (Istio "manual deployment" mode).
resource "helm_release" "istio_ingress" {
  name             = local.ingress_name
  repository       = "https://istio-release.storage.googleapis.com/charts"
  chart            = "gateway"
  version          = var.versions.istio
  namespace        = local.ingress_namespace
  create_namespace = true
  wait             = true

  values = [yamlencode({
    replicaCount = 2
    autoscaling  = { enabled = true, minReplicas = 2, maxReplicas = 5 }
    service = {
      type = "LoadBalancer"
      annotations = {
        "service.beta.kubernetes.io/aws-load-balancer-type"            = "external"
        "service.beta.kubernetes.io/aws-load-balancer-nlb-target-type" = "ip"
        "service.beta.kubernetes.io/aws-load-balancer-scheme"          = "internet-facing"
        # TLS is terminated by Istio with the cert-manager certificates: the NLB is plain TCP
      }
    }
  })]

  depends_on = [helm_release.istiod, helm_release.aws_load_balancer_controller, module.vpc]
}

data "kubernetes_service_v1" "istio_ingress" {
  metadata {
    name      = local.ingress_name
    namespace = local.ingress_namespace
  }
  depends_on = [helm_release.istio_ingress]
}

# --- ArgoCD: GitOps engine that deploys the app requests from Git ---
resource "helm_release" "argo_cd" {
  name             = "argocd"
  repository       = "https://argoproj.github.io/argo-helm"
  chart            = "argo-cd"
  version          = var.versions.argo_cd
  namespace        = "argocd"
  create_namespace = true
  wait             = true

  values = [yamlencode({
    global = { domain = "${var.argocd_subdomain}.${var.domain}" }
    configs = {
      params = { "server.insecure" = true } # TLS ends at the Istio gateway
    }
  })]

  depends_on = [module.eks, module.vpc]
}

# --- Platform configuration (needs the CRDs of all the components above) ---
resource "helm_release" "platform_config" {
  name      = "platform-config"
  chart     = "${path.module}/charts/platform-config"
  namespace = "argocd"
  wait      = true

  values = [yamlencode({
    domain = var.domain
    region = var.region
    letsencrypt = {
      server       = var.letsencrypt_server
      email        = var.letsencrypt_email
      hostedZoneId = data.aws_route53_zone.this.zone_id
    }
    ingress = {
      serviceDNS = local.ingress_service_dns
      lbHostname = data.kubernetes_service_v1.istio_ingress.status[0].load_balancer[0].ingress[0].hostname
    }
    argocd = {
      host = "${var.argocd_subdomain}.${var.domain}"
    }
    gitops = {
      repoURL   = var.gitops_repo_url
      revision  = var.gitops_revision
      appsPath  = "apps"
      chartPath = "app-template"
    }
  })]

  depends_on = [
    helm_release.cert_manager,
    helm_release.external_dns,
    helm_release.istio_ingress,
    helm_release.argo_cd,
  ]
}

# --- Clean teardown: before Helm uninstalls ArgoCD/ExternalDNS/the controllers, delete the apps
#     (pods, certificates, DNS records) and wait until ExternalDNS removed their records. ---
resource "terraform_data" "pre_destroy" {
  input = {
    cluster = module.eks.cluster_name
    region  = var.region
    zone_id = data.aws_route53_zone.this.zone_id
    owner   = var.cluster_name
    script  = "${path.module}/scripts/pre-destroy.sh"
  }

  provisioner "local-exec" {
    when        = destroy
    interpreter = ["bash", "-c"]
    command     = "bash '${self.input.script}' '${self.input.cluster}' '${self.input.region}' '${self.input.zone_id}' '${self.input.owner}'"
  }

  # module.vpc: the NAT gateway and the routes must outlive the cleanup. Without it, terraform deletes
  # the NAT gateway in parallel: the controllers lose AWS access (Pod Identity needs the EKS Auth
  # endpoint), the NLB and the DNS records are never deleted, and the VPC cannot be destroyed.
  depends_on = [helm_release.platform_config, module.vpc]
}
