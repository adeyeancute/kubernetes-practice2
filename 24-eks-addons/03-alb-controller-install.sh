#!/usr/bin/env bash
# Install the AWS Load Balancer Controller on an EKS cluster (same steps as chapter 07).
# Skip this script if you already installed the controller in chapter 07.
#
# Usage:
#   ./03-alb-controller-install.sh <cluster-name> <aws-account-id>
# Example:
#   ./03-alb-controller-install.sh my-cluster 123456789012

set -euo pipefail

CLUSTER="${1:?cluster name required}"
ACCOUNT_ID="${2:?aws account id required}"
REGION="${AWS_REGION:-us-east-1}"
LBC_VERSION="3.6.0"   # controller version; the IAM policy must come from the same version
POLICY_ARN="arn:aws:iam::${ACCOUNT_ID}:policy/AWSLoadBalancerControllerIAMPolicy"

if helm status aws-load-balancer-controller -n kube-system >/dev/null 2>&1; then
  echo "The AWS Load Balancer Controller is already installed (chapter 07). Nothing to do."
  exit 0
fi

# 1. IAM policy for the controller, from the same version as the chart. Update it if it already exists.
curl -sSL "https://raw.githubusercontent.com/kubernetes-sigs/aws-load-balancer-controller/v${LBC_VERSION}/docs/install/iam_policy.json" -o iam_policy.json
if aws iam get-policy --policy-arn "$POLICY_ARN" >/dev/null 2>&1; then
  aws iam create-policy-version --policy-arn "$POLICY_ARN" --policy-document file://iam_policy.json --set-as-default >/dev/null
else
  aws iam create-policy --policy-name AWSLoadBalancerControllerIAMPolicy --policy-document file://iam_policy.json >/dev/null
fi

# 2. IRSA ServiceAccount for the controller.
eksctl create iamserviceaccount \
  --cluster "$CLUSTER" --region "$REGION" \
  --namespace kube-system \
  --name aws-load-balancer-controller \
  --attach-policy-arn "$POLICY_ARN" \
  --override-existing-serviceaccounts \
  --approve

# 3. Helm chart.
VPC_ID=$(aws eks describe-cluster --name "$CLUSTER" --region "$REGION" --query cluster.resourcesVpcConfig.vpcId --output text)
helm repo add eks https://aws.github.io/eks-charts
helm repo update eks
helm install aws-load-balancer-controller eks/aws-load-balancer-controller -n kube-system --version "$LBC_VERSION" \
  --set clusterName="$CLUSTER" \
  --set region="$REGION" \
  --set vpcId="$VPC_ID" \
  --set serviceAccount.create=false \
  --set serviceAccount.name=aws-load-balancer-controller \
  --set enableServiceMutatorWebhook=false \
  --wait

# 4. Verify.
kubectl -n kube-system get deployment aws-load-balancer-controller
echo
echo "Done. Ingress objects with spec.ingressClassName: alb now create real ALBs."
