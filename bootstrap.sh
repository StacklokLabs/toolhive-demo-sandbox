#!/bin/bash
set -e

# Bootstrap script for ToolHive demo-in-a-box Kubernetes cluster

## Requirements:
# - kind
# - kubectl
# - helm
# - ToolHive CLI (thv)
# - ngrok account with authtoken and API key stored as ToolHive secrets
# - GitHub token stored as ToolHive secret
# - Okta client secret stored as ToolHive secret

# Source common helper functions
. "$(dirname "$0")/helpers.sh"

echo "Running preflight checks..."

# Check for required binaries
echo -n "Checking required binaries..."
MISSING_BINARIES=""
for binary in kind kubectl helm thv; do
    if ! command -v "$binary" > /dev/null 2>&1; then
        MISSING_BINARIES="$MISSING_BINARIES $binary"
    fi
done
if [ -n "$MISSING_BINARIES" ]; then
    die "Missing required binaries:$MISSING_BINARIES"
fi
echo " ✓"

# Fetch and validate ToolHive secrets
echo -n "Fetching ToolHive secrets..."
GITHUB_TOKEN=$(thv secret get github 2>/dev/null)
if [ -z "$GITHUB_TOKEN" ]; then
    die "ToolHive secret 'github' is empty or does not exist"
fi

NGROK_AUTHTOKEN=$(thv secret get ngrok-authtoken 2>/dev/null)
if [ -z "$NGROK_AUTHTOKEN" ]; then
    die "ToolHive secret 'ngrok-authtoken' is empty or does not exist"
fi

NGROK_API_KEY=$(thv secret get ngrok-api-key 2>/dev/null)
if [ -z "$NGROK_API_KEY" ]; then
    die "ToolHive secret 'ngrok-api-key' is empty or does not exist"
fi

# OKTA_CLIENT_SECRET=$(thv secret get okta-client-secret 2>/dev/null)
# if [ -z "$OKTA_CLIENT_SECRET" ]; then
#     die "ToolHive secret 'okta-client-secret' is empty or does not exist"
# fi
echo " ✓"

# Load environment variables from .env if it exists
if [ -f "$(dirname "$0")/.env" ]; then
    set -a  # automatically export all variables
    source "$(dirname "$0")/.env"
    set +a  # turn off automatic export
fi

# Prompt for ngrok domain if not set in .env
if [ -z "$NGROK_DOMAIN" ]; then
    read -p "Enter your ngrok domain (hostname only, e.g., example.ngrok-free.dev): " NGROK_DOMAIN
    export NGROK_DOMAIN
fi

echo -n "Creating Kind cluster..."
if kind get clusters 2>/dev/null | grep -q "^toolhive-demo-in-a-box$"; then
    echo " (already exists, skipping)"
else
    run_quiet kind create cluster --name toolhive-demo-in-a-box || die "Failed to create Kind cluster"
    echo " ✓"
fi
run_quiet sh -c "kind get kubeconfig --name toolhive-demo-in-a-box > kubeconfig-toolhive-demo.yaml" || die "Failed to get kubeconfig"
export KUBECONFIG=$(pwd)/kubeconfig-toolhive-demo.yaml

# Traefik chart installs Gateway API CRDs automatically, installing them separately breaks things.
#echo "Installing Gateway API..."
#kubectl apply --server-side -f https://github.com/kubernetes-sigs/gateway-api/releases/download/v1.4.1/standard-install.yaml

# Add Helm repos and update
echo -n "Adding Helm repositories..."
run_quiet helm repo add traefik https://traefik.github.io/charts || die "Failed to add Traefik repo"
run_quiet helm repo add ngrok https://charts.ngrok.com || die "Failed to add ngrok repo"
run_quiet helm repo add grafana https://grafana.github.io/helm-charts || die "Failed to add Grafana repo"
echo " ✓"

echo -n "Updating Helm repositories..."
run_quiet helm repo update || die "Failed to update Helm repos"
echo " ✓"

# Reference: https://doc.traefik.io/traefik/getting-started/kubernetes/
echo -n "Installing Traefik..."
run_quiet helm upgrade --install traefik traefik/traefik --version 37.4.0 --namespace traefik --create-namespace --values traefik-helm-values.yaml --wait || die "Failed to install Traefik"
echo " ✓"

# Reference: https://ngrok.com/docs/getting-started/kubernetes/gateway-api
echo -n "Installing ngrok Operator..."
if ! namespace_exists ngrok-operator; then
    run_quiet kubectl create namespace ngrok-operator || die "Failed to create ngrok-operator namespace"
fi
if ! secret_exists ngrok-operator-credentials ngrok-operator; then
    run_quiet kubectl create secret generic ngrok-operator-credentials --namespace ngrok-operator \
        --from-literal=API_KEY="$NGROK_API_KEY" \
        --from-literal=AUTHTOKEN="$NGROK_AUTHTOKEN" || die "Failed to create ngrok credentials secret"
fi
run_quiet helm upgrade --install ngrok-operator ngrok/ngrok-operator --version 0.21.1 --namespace ngrok-operator --create-namespace --set defaultDomainReclaimPolicy=Retain --set credentials.secret.name=ngrok-operator-credentials --wait || die "Failed to install ngrok Operator"
run_quiet sh -c "envsubst < ngrok-gateway.yaml | kubectl apply -f -" || die "Failed to apply ngrok gateway"
echo " ✓"

echo -n "Installing cert-manager..."
run_quiet helm upgrade --install cert-manager oci://quay.io/jetstack/charts/cert-manager --version v1.19.2 --namespace cert-manager --create-namespace --set crds.enabled=true || die "Failed to install cert-manager"
echo " ✓"

echo -n "Installing observability stack..."
if ! namespace_exists observability; then
    run_quiet kubectl create namespace observability || die "Failed to create observability namespace"
fi
run_quiet kubectl apply -f https://github.com/open-telemetry/opentelemetry-operator/releases/latest/download/opentelemetry-operator.yaml || die "Failed to install OpenTelemetry Operator"
run_quiet kubectl wait --for=condition=available --timeout=300s deployment/opentelemetry-operator-controller-manager -n opentelemetry-operator-system || die "OpenTelemetry Operator failed to become ready"
run_quiet kubectl apply -f otel-collector.yaml || die "Failed to apply OTel collector config"
run_quiet helm upgrade --install tempo grafana/tempo --namespace observability --wait || die "Failed to install Tempo"
run_quiet helm upgrade --install grafana grafana/grafana --namespace observability --values grafana-helm-values.yaml --wait || die "Failed to install Grafana"
echo " ✓"

# Reference: https://docs.stacklok.com/toolhive/tutorials/quickstart-k8s
echo -n "Installing ToolHive Operator..."
run_quiet helm upgrade --install toolhive-operator-crds oci://ghcr.io/stacklok/toolhive/toolhive-operator-crds --version 0.0.85 --wait || die "Failed to install ToolHive Operator CRDs"
run_quiet helm upgrade --install toolhive-operator oci://ghcr.io/stacklok/toolhive/toolhive-operator --version 0.5.13 --namespace toolhive-system --create-namespace --wait || die "Failed to install ToolHive Operator"
echo " ✓"

echo -n "Creating secrets..."
if ! secret_exists github-token toolhive-system; then
    run_quiet kubectl create secret generic github-token --namespace toolhive-system --from-literal=token="$GITHUB_TOKEN" || die "Failed to create github-token secret"
fi
# if ! secret_exists okta-client-secret toolhive-system; then
#     run_quiet kubectl create secret generic okta-client-secret --namespace toolhive-system --from-literal=token="$OKTA_CLIENT_SECRET" || die "Failed to create okta-client-secret secret"
# fi
echo " ✓"

echo -n "Installing Registry Server..."
run_quiet kubectl apply -f registry-server.yaml || die "Failed to install Registry Server"
echo " ✓"

read -p "Now, run 'cloud-provider-kind' in another terminal to assign an IP to the traefik gateway. Press Enter to continue once running..."

TRAEFIK_IP=$(kubectl get gateways --namespace traefik traefik-gateway -o "jsonpath={.status.addresses[0].value}")
TRAEFIK_HOSTNAME="mcp-${TRAEFIK_IP//./-}.traefik.me"

# Expose Grafana via Traefik, using its own hostname for simplicity
echo -n "Configuring Grafana HTTPRoute..."
GRAFANA_HOSTNAME="grafana-${TRAEFIK_IP//./-}.traefik.me"
run_quiet sh -c "envsubst < grafana-httproute.yaml | kubectl apply -f -" || die "Failed to apply Grafana HTTPRoute"
echo " ✓"

echo -n "Installing MKP MCP server..."
run_quiet sh -c "envsubst < demo-manifests/mcpserver-mkp.yaml | kubectl apply -f -" || die "Failed to install MKP MCP server"
echo " ✓"

echo -n "Installing vMCP demo servers..."
run_quiet kubectl apply -f demo-manifests/vmcp-mcpservers.yaml || die "Failed to apply vMCP MCP servers"
# Wait for MCPServer resources to reach Running phase
run_quiet kubectl wait --for=jsonpath='{.status.phase}'=Running --timeout=300s mcpserver --all -n toolhive-system || die "MCPServer resources failed to become ready"
run_quiet sh -c "envsubst < demo-manifests/vmcp-demo-simple.yaml | kubectl apply -f -" || die "Failed to apply vMCP demo"
# run_quiet sh -c "envsubst < demo-manifests/vmcp-demo-auth.yaml | kubectl apply -f -" || die "Failed to apply vMCP demo with auth"
echo " ✓"

echo "Bootstrap complete! Access your demo services at the following URLs:"
echo " - ToolHive Registry Server at https://$NGROK_DOMAIN/registry"
echo " - MKP MCP server at http://$TRAEFIK_HOSTNAME/mkp/mcp"
echo " - vMCP demo server at http://$TRAEFIK_HOSTNAME/vmcp-demo/mcp"
echo " - Grafana at http://$GRAFANA_HOSTNAME"