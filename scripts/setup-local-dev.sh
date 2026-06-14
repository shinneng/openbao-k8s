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

# 5b. Create the openbao root token secret if provided (env var or local file).
# The automation Job (`openbao-config`) expects a secret named `openbao-root-token`
# with a key `token`. For local development you can set OPENBAO_ROOT_TOKEN or
# place the token in `secrets/openbao-root-token.token`.
echo "🔐 Ensuring openbao-root-token secret exists (if provided)..."
if kubectl -n openbao get secret openbao-root-token &> /dev/null; then
    echo "✅ Secret openbao-root-token already exists in namespace openbao."
else
    TOKEN_SOURCE=""
    if [ -n "${OPENBAO_ROOT_TOKEN:-}" ]; then
        TOKEN_SOURCE="env"
        TOKEN_VAL="$OPENBAO_ROOT_TOKEN"
    elif [ -f "secrets/openbao-root-token.token" ]; then
        TOKEN_SOURCE="file"
        TOKEN_VAL="$(cat secrets/openbao-root-token.token)"
    fi

    if [ -n "$TOKEN_SOURCE" ]; then
        echo "Creating Kubernetes secret openbao-root-token from $TOKEN_SOURCE..."
        kubectl -n openbao create secret generic openbao-root-token \
            --from-literal=token="$TOKEN_VAL" --dry-run=client -o yaml | kubectl apply -f -
        echo "✅ openbao-root-token created/applied."
    else
        echo "⚠️  openbao-root-token was not provided. To automate OpenBao configuration,"
        echo "    set OPENBAO_ROOT_TOKEN environment variable or create the file:"
        echo "      secrets/openbao-root-token.token"
        echo "    The repository ignores the secrets/ directory so your token won't be committed."
    fi
fi

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

## 10. Initialize and/or unseal OpenBao if necessary (local-only automation)
echo "🔁 Checking OpenBao initialization/unseal status..."

# Wait for at least one OpenBao server pod to appear
echo "⏳ Waiting for OpenBao server pod..."
for i in {1..60}; do
    POD=$(kubectl -n openbao get pods -l app.kubernetes.io/name=openbao -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)
    if [ -n "$POD" ]; then
        READY=$(kubectl -n openbao get pod "$POD" -o jsonpath='{.status.phase}' 2>/dev/null || true)
        if [ "$READY" = "Running" ]; then
            echo "✅ Found running OpenBao pod: $POD"
            break
        fi
    fi
    sleep 5
done
if [ -z "$POD" ]; then
    echo "⚠️  No OpenBao pod found after waiting; skipping auto-init/unseal."
else
    # Wait until bao CLI responds with JSON status (may return non-zero if not ready)
    echo "⏳ Waiting for bao status endpoint to respond..."
    for i in {1..60}; do
        if kubectl -n openbao exec "$POD" -- bao status -format=json > /tmp/bao_status.json 2>/dev/null; then
            break
        fi
        sleep 3
    done

    if [ ! -s /tmp/bao_status.json ]; then
        echo "⚠️  Could not get bao status JSON; skipping auto-init/unseal."
    else
        INIT=$(python3 - <<'PY'
import json,sys
obj=json.load(open('/tmp/bao_status.json'))
print('1' if obj.get('initialized') else '0')
print('1' if obj.get('sealed') else '0')
PY
)
        INITIALIZED=$(printf "%s" "$INIT" | sed -n '1p')
        SEALED=$(printf "%s" "$INIT" | sed -n '2p')

        if [ "$INITIALIZED" = "0" ]; then
            echo "🔧 OpenBao is not initialized. Initializing (1 key share / threshold 1)..."
            INIT_OUT=$(kubectl -n openbao exec "$POD" -- bao operator init -format=json -key-shares=1 -key-threshold=1 2>/dev/null || true)
            if [ -z "$INIT_OUT" ]; then
                echo "❌ Initialization failed or did not return JSON. Check pod logs: kubectl -n openbao logs $POD"
            else
                # Parse root_token and unseal key using python
                ROOT_TOKEN=$(printf "%s" "$INIT_OUT" | python3 -c "import sys,json;obj=json.load(sys.stdin);print(obj.get('root_token',''))")
                UNSEAL_KEY=$(printf "%s" "$INIT_OUT" | python3 -c "import sys,json;obj=json.load(sys.stdin);print(obj.get('unseal_keys_b64',[None])[0])")

                if [ -n "$ROOT_TOKEN" ]; then
                    echo "Creating Kubernetes secret openbao-root-token..."
                    kubectl -n openbao create secret generic openbao-root-token --from-literal=token="$ROOT_TOKEN" --dry-run=client -o yaml | kubectl apply -f -
                    mkdir -p secrets
                    echo "$ROOT_TOKEN" > secrets/openbao-root-token.token
                    echo "✅ Root token saved to secrets/openbao-root-token.token (ignored by git)."
                fi
                if [ -n "$UNSEAL_KEY" ]; then
                    mkdir -p secrets
                    echo "$UNSEAL_KEY" > secrets/openbao-unseal.key
                    echo "✅ Unseal key saved to secrets/openbao-unseal.key (ignored by git)."
                fi

                # Unseal all OpenBao server pods using the first unseal key
                if [ -n "$UNSEAL_KEY" ]; then
                    echo "🔓 Unsealing OpenBao server pods..."
                    for p in $(kubectl -n openbao get pods -l app.kubernetes.io/name=openbao -o jsonpath='{.items[*].metadata.name}'); do
                        echo "Unsealing $p..."
                        kubectl -n openbao exec "$p" -- bao operator unseal "$UNSEAL_KEY" || true
                    done
                    echo "✅ Unseal commands issued."
                fi
            fi
        else
            if [ "$SEALED" = "1" ]; then
                echo "🔐 OpenBao is initialized but sealed. Attempting to unseal using available key..."
                # Prefer env override, then file
                if [ -n "${OPENBAO_UNSEAL_KEY:-}" ]; then
                    USE_KEY="$OPENBAO_UNSEAL_KEY"
                elif [ -f "secrets/openbao-unseal.key" ]; then
                    USE_KEY="$(cat secrets/openbao-unseal.key)"
                else
                    USE_KEY=""
                fi

                if [ -n "$USE_KEY" ]; then
                    for p in $(kubectl -n openbao get pods -l app.kubernetes.io/name=openbao -o jsonpath='{.items[*].metadata.name}'); do
                        echo "Unsealing $p..."
                        kubectl -n openbao exec "$p" -- bao operator unseal "$USE_KEY" || true
                    done
                    echo "✅ Unseal commands issued."
                else
                    echo "⚠️  No unseal key available (set OPENBAO_UNSEAL_KEY or create secrets/openbao-unseal.key)."
                fi
            else
                echo "✅ OpenBao is initialized and unsealed."
            fi
        fi
    fi
fi

echo ""
echo "🎉 Setup complete! Next steps:"
echo "1. Verify all components are running: kubectl get pods -A"
echo "2. Check HelmReleases status: flux get helmreleases -A"
echo ""
echo "Tips:"
echo "- OpenBao will be available at localhost:8200 if you port-forward:"
echo "  kubectl port-forward -n openbao svc/openbao 8200:8200"
echo "- Check the automation job: kubectl get jobs -n openbao"
