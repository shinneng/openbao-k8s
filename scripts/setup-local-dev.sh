#!/bin/bash

# setup-local-dev.sh
# Automates the setup of a local kind cluster for testing the openbao-k8s stack.

set -e

CLUSTER_NAME="openbao-dev"

echo "🚀 Starting local development setup for OpenBao..."

# 1. Create kind cluster
if ! kind get clusters | grep -q "^$CLUSTER_NAME$"; then
    echo "🏗️ Creating kind cluster: $CLUSTER_NAME..."
    cat <<EOF | kind create cluster --name "$CLUSTER_NAME" --config=-
kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4
nodes:
- role: control-plane
  extraPortMappings:
  - containerPort: 80
    hostPort: 80
    protocol: TCP
  - containerPort: 443
    hostPort: 443
    protocol: TCP
EOF
else
    echo "✅ Cluster $CLUSTER_NAME already exists."
fi

# 2. Install Gateway API CRDs (required for Istio + Gateway API)
# We apply these first from the local manifests to prevent race conditions (chicken-and-egg)
# when applying the Gateway/HTTPRoute custom resources in step 5.
echo "📦 Installing Gateway API CRDs..."
kubectl apply -k infrastructure/base/gateway-api

# 3. Check for Flux CLI
if ! command -v flux &> /dev/null; then
    echo "⚠️ Flux CLI not found. Please install it: https://fluxcd.io/flux/installation/"
    exit 1
fi

# 4. Install Flux Controllers
echo "🔧 Installing Flux controllers..."
flux install

# 5. Create required namespaces
echo "📁 Creating required namespaces..."
for ns in openbao database istio-system external-secrets semaphoreui cert-manager cnpg-system; do
    kubectl create namespace "$ns" --dry-run=client -o yaml | kubectl apply -f -
done

# 6. Apply HelmRepositories (so Flux controllers can fetch charts)
echo "📦 Applying HelmRepositories..."
kubectl apply -f infrastructure/sources/helmrepositories.yaml
flux reconcile source helm cnpg -n flux-system
flux reconcile source helm jetstack -n flux-system
flux reconcile source helm istio -n flux-system
flux reconcile source helm openbao -n flux-system
flux reconcile source helm external-secrets -n flux-system
flux reconcile source helm semaphoreui -n flux-system

# 7. Apply Operator HelmReleases and wait for them to register CRDs
echo "⚙️ Deploying operators (cert-manager, CloudNativePG, Istio base)..."
kubectl apply -f infrastructure/base/cert-manager/helmrelease.yaml
kubectl apply -f infrastructure/base/cloudnativepg/operator.yaml
kubectl apply -f infrastructure/base/istio/helmreleases.yaml

echo "⏳ Waiting for operators to reconcile and install CRDs..."
flux reconcile helmrelease -n cert-manager cert-manager
flux reconcile helmrelease -n cnpg-system cnpg-operator
flux reconcile helmrelease -n istio-system istio-base
flux reconcile helmrelease -n istio-system istiod

# 8. Apply the remaining dev stack manifests (now that all CRDs exist)
echo "🛠️ Applying dev stack manifests..."
kubectl apply -k clusters/dev

# 9. Force sync the rest of the HelmReleases
echo "⏳ Syncing final applications..."
flux reconcile helmrelease -n openbao openbao
flux reconcile helmrelease -n external-secrets external-secrets
flux reconcile helmrelease -n semaphoreui semaphoreui

echo ""
echo "🎉 Setup complete! Next steps:"
echo "1. Verify all components are running: kubectl get pods -A"
echo "2. Check HelmReleases status: flux get helmreleases -A"
echo ""
echo "Tips:"
echo "- OpenBao will be available at localhost:8200 if you port-forward:"
echo "  kubectl port-forward -n openbao svc/openbao 8200:8200"
echo "- Check the automation job: kubectl get jobs -n openbao"
