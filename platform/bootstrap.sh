#!/usr/bin/env bash
# Rebuild the SecureShop platform on a fresh k3s cluster, from Git only.
# Order matters: cert-manager and ArgoCD first, then the policy engines and
# their policies, and only then hand the app over to ArgoCD, so the very
# first app pods are already checked by Pod Security, Gatekeeper and Kyverno.
set -euo pipefail
cd "$(dirname "$0")"

echo "== 1. Helm repositories"
while read -r name url; do helm repo add "$name" "$url" > /dev/null; done < helm/repos.txt
helm repo update > /dev/null

echo "== 2. Charts (versions pinned, values from Git)"
install() {  # release namespace chart version
  helm upgrade --install "$1" "$3" -n "$2" --create-namespace --version "$4" \
    -f "helm/$1-values.yaml" --wait --timeout 10m
}
install cert-manager cert-manager       jetstack/cert-manager  v1.21.2
install argocd       argocd             argo/argo-cd           10.10.0
install gatekeeper   gatekeeper-system  gatekeeper/gatekeeper  3.23.1
install kyverno      kyverno            kyverno/kyverno        3.9.1

echo "== 3. Platform configuration and policies"
kubectl apply -f cluster-issuers.yaml
kubectl apply -f gatekeeper/templates/
echo "   waiting for Gatekeeper to create the constraint types..."
for crd in k8sallowedrepos k8sdisallowedtags k8srequireimagedigest k8srequiredlabels; do
  until kubectl get crd "$crd.constraints.gatekeeper.sh" > /dev/null 2>&1; do sleep 5; done
done
kubectl apply -f gatekeeper/expansion.yaml
kubectl apply -f gatekeeper/constraints.yaml
kubectl apply -f kyverno/

echo "== 4. Hand the app over to ArgoCD"
kubectl apply -f ../apps/project.yaml -f ../apps/secureshop-dev.yaml

echo "== 5. Access rules (once ArgoCD has created the namespaces)"
until kubectl get ns web app > /dev/null 2>&1; do sleep 5; done
kubectl apply -f rbac/

echo "== Done. Remaining manual steps: rotate the ArgoCD admin password, update the ingress hostname."
