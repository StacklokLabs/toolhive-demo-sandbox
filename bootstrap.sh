#!/bin/bash
set -e
set -a  # automatically export all variables for subshells

# Bootstrap script for ToolHive demo-in-a-box Kubernetes cluster

## Requirements:
# - kind
# - kubectl
# - helm

# Version pins to ensure consistent demo environment
TRAEFIK_CHART_VERSION="39.0.1" # renovate: datasource=helm depName=traefik registryUrl=https://traefik.github.io/charts
CERT_MANAGER_CHART_VERSION="v1.19.3" # renovate: datasource=docker depName=quay.io/jetstack/charts/cert-manager versioning=semver
OPENTELEMETRY_OPERATOR_VERSION="v0.144.0" # renovate: datasource=github-releases depName=open-telemetry/opentelemetry-operator
TEMPO_CHART_VERSION="1.26.2" # renovate: datasource=helm depName=tempo registryUrl=https://grafana-community.github.io/helm-charts
PROMETHEUS_CHART_VERSION="28.9.1" # renovate: datasource=helm depName=prometheus registryUrl=https://prometheus-community.github.io/helm-charts
GRAFANA_CHART_VERSION="11.1.7" # renovate: datasource=helm depName=grafana registryUrl=https://grafana-community.github.io/helm-charts
CLOUDNATIVE_PG_CHART_VERSION="0.27.1" # renovate: datasource=helm depName=cloudnative-pg registryUrl=https://cloudnative-pg.github.io/charts
TOOLHIVE_OPERATOR_CRDS_CHART_VERSION="0.9.3" # renovate: datasource=docker depName=ghcr.io/stacklok/toolhive/toolhive-operator-crds
TOOLHIVE_OPERATOR_CHART_VERSION="0.9.3" # renovate: datasource=docker depName=ghcr.io/stacklok/toolhive/toolhive-operator
REGISTRY_SERVER_CHART_VERSION="0.6.2" # renovate: datasource=docker depName=ghcr.io/stacklok/toolhive-registry-server
CLOUD_UI_VERSION="v0.1.0" # renovate: datasource=docker depName=ghcr.io/stacklok/toolhive-cloud-ui
MCP_OPTIMIZER_CHART_VERSION="0.2.5" # renovate: datasource=docker depName=ghcr.io/stackloklabs/mcp-optimizer/mcp-optimizer

# Source common helper functions
. "$(dirname "$0")/helpers.sh"

echo "Running preflight checks..."

# Check for required binaries
echo -n "  Checking required binaries..."
MISSING_BINARIES=""
for binary in kind cloud-provider-kind kubectl helm; do
    if ! command -v "$binary" > /dev/null 2>&1; then
        MISSING_BINARIES="$MISSING_BINARIES $binary"
    fi
done
if [ -n "$MISSING_BINARIES" ]; then
    die "Missing required binaries:$MISSING_BINARIES"
fi
echo " ✓"

# Fetch and validate ToolHive secrets
# echo -n "  Fetching ToolHive secrets..."

# OKTA_CLIENT_SECRET=$(thv secret get okta-client-secret 2>/dev/null)
# if [ -z "$OKTA_CLIENT_SECRET" ]; then
#     die "ToolHive secret 'okta-client-secret' is empty or does not exist"
# fi
# echo " ✓"

# Load environment variables from .env if it exists
if [ -f "$(dirname "$0")/.env" ]; then
    source "$(dirname "$0")/.env"
fi

echo -n "Creating Kind cluster..."
if kind get clusters 2>/dev/null | grep -q "^toolhive-demo-in-a-box$"; then
    echo " (already exists, skipping)"
else
    run_quiet kind create cluster --config "$(dirname "$0")/kind-config.yaml" || die "Failed to create Kind cluster"
    echo " ✓"
fi
run_quiet sh -c "kind get kubeconfig --name toolhive-demo-in-a-box > kubeconfig-toolhive-demo.yaml" || die "Failed to get kubeconfig"
export KUBECONFIG=$(pwd)/kubeconfig-toolhive-demo.yaml

# Traefik chart installs Gateway API CRDs automatically, installing them separately breaks things.
# echo "Installing Gateway API..."
# kubectl apply --server-side -f https://github.com/kubernetes-sigs/gateway-api/releases/download/v1.4.1/standard-install.yaml

# Add Helm repos and update
echo -n "Adding Helm repositories..."
run_quiet helm repo add traefik https://traefik.github.io/charts || die "Failed to add Traefik repo"
run_quiet helm repo add grafana-community https://grafana-community.github.io/helm-charts || die "Failed to add Grafana Community repo"
run_quiet helm repo add prometheus-community https://prometheus-community.github.io/helm-charts || die "Failed to add Prometheus repo"
run_quiet helm repo add cnpg https://cloudnative-pg.github.io/charts || die "Failed to add CloudNativePG repo"
echo " ✓"

echo -n "Updating Helm repositories..."
run_quiet helm repo update || die "Failed to update Helm repos"
echo " ✓"

if ! namespace_exists traefik; then
    run_quiet kubectl create namespace traefik || die "Failed to create traefik namespace"
fi

echo -n "Installing cert-manager..."
run_quiet helm upgrade --install cert-manager oci://quay.io/jetstack/charts/cert-manager --version "$CERT_MANAGER_CHART_VERSION" --namespace cert-manager --create-namespace --set crds.enabled=true || die "Failed to install cert-manager"
run_quiet kubectl apply -f infra/cert-manager-certs.yaml || die "Failed to apply cert-manager certs"
echo " ✓"

# Reference: https://doc.traefik.io/traefik/getting-started/kubernetes/
echo -n "Installing Traefik..."
run_quiet helm upgrade --install traefik traefik/traefik --version "$TRAEFIK_CHART_VERSION" --namespace traefik --create-namespace --values infra/traefik-helm-values.yaml --wait || die "Failed to install Traefik"
echo " ✓"

echo -n "Installing observability stack..."
if ! namespace_exists observability; then
    run_quiet kubectl create namespace observability || die "Failed to create observability namespace"
fi
run_quiet kubectl apply -f https://github.com/open-telemetry/opentelemetry-operator/releases/download/${OPENTELEMETRY_OPERATOR_VERSION}/opentelemetry-operator.yaml || die "Failed to install OpenTelemetry Operator"
run_quiet kubectl wait --for=condition=available --timeout=5m deployment/opentelemetry-operator-controller-manager --namespace opentelemetry-operator-system || die "OpenTelemetry Operator failed to become ready"
run_quiet helm upgrade --install tempo grafana-community/tempo --version "$TEMPO_CHART_VERSION" --namespace observability --wait || die "Failed to install Tempo"
run_quiet helm upgrade --install prometheus prometheus-community/prometheus --version "$PROMETHEUS_CHART_VERSION" --namespace observability --values infra/prometheus-helm-values.yaml --wait || die "Failed to install Prometheus"
run_quiet helm upgrade --install grafana grafana-community/grafana --version "$GRAFANA_CHART_VERSION" --namespace observability --values infra/grafana-helm-values.yaml --set-file dashboards.default.toolhive-mcp.json=infra/grafana-dashboard.json --wait || die "Failed to install Grafana"
run_quiet kubectl apply -f infra/otel-collector.yaml || die "Failed to apply OTel collector config"
echo " ✓"

# Reference: https://docs.stacklok.com/toolhive/tutorials/quickstart-k8s
echo -n "Installing ToolHive Operator..."
run_quiet helm upgrade --install toolhive-operator-crds oci://ghcr.io/stacklok/toolhive/toolhive-operator-crds --version "$TOOLHIVE_OPERATOR_CRDS_CHART_VERSION" --wait || die "Failed to install ToolHive Operator CRDs"
run_quiet helm upgrade --install toolhive-operator oci://ghcr.io/stacklok/toolhive/toolhive-operator --version "$TOOLHIVE_OPERATOR_CHART_VERSION" --namespace toolhive-system --create-namespace --wait || die "Failed to install ToolHive Operator"
echo " ✓"

# echo -n "Creating secrets..."
# if ! secret_exists okta-client-secret toolhive-system; then
#     run_quiet kubectl create secret generic okta-client-secret --namespace toolhive-system --from-literal=token="$OKTA_CLIENT_SECRET" || die "Failed to create okta-client-secret secret"
# fi
# echo " ✓"

# Check if traefik gateway already has an IP assigned
echo -n "Checking for Traefik Gateway IP..."
TRAEFIK_IP=$(kubectl get gateways --namespace traefik traefik-gateway -o "jsonpath={.status.addresses[0].value}" 2>/dev/null || echo "")

if [ -z "$TRAEFIK_IP" ]; then
    echo " (no IP yet)"
    echo ""
    read -p "Run 'sudo cloud-provider-kind' in another terminal to assign an IP to the traefik gateway. Press Enter to continue once running..."
    
    # Wait for the IP to be assigned (with timeout)
    echo -n "Waiting for IP assignment..."
    for i in {1..30}; do
        TRAEFIK_IP=$(kubectl get gateways --namespace traefik traefik-gateway -o "jsonpath={.status.addresses[0].value}" 2>/dev/null || echo "")
        if [ -n "$TRAEFIK_IP" ]; then
            echo " ✓ ($TRAEFIK_IP)"
            break
        fi
        sleep 1
    done
    
    if [ -z "$TRAEFIK_IP" ]; then
        die "Timeout waiting for Traefik Gateway IP. Is cloud-provider-kind running?"
    fi
else
    echo " ✓ ($TRAEFIK_IP)"
fi

TRAEFIK_HOSTNAME_BASE="${TRAEFIK_IP//./-}.traefik.me"
MCP_HOSTNAME="mcp-${TRAEFIK_HOSTNAME_BASE}"
REGISTRY_HOSTNAME="registry-${TRAEFIK_HOSTNAME_BASE}"
UI_HOSTNAME="ui-${TRAEFIK_HOSTNAME_BASE}"
AUTH_HOSTNAME="auth-${TRAEFIK_HOSTNAME_BASE}"
GRAFANA_HOSTNAME="grafana-${TRAEFIK_HOSTNAME_BASE}"

echo -n "Creating PostgreSQL server for ToolHive Registry Server..."
run_quiet helm upgrade --install cloudnative-pg cnpg/cloudnative-pg --version "$CLOUDNATIVE_PG_CHART_VERSION" --namespace cnpg-system --create-namespace --wait || die "Failed to install CloudNativePG Operator"
run_quiet kubectl apply -f demo-manifests/registry-server-db.yaml || die "Failed to create PostgreSQL server for Registry Server"
run_quiet kubectl wait --for=condition=Ready cluster/registry-db -n toolhive-system --timeout=5m || die "PostgreSQL server for Registry Server failed to become ready"
echo " ✓"

echo -n "Installing Registry Server..."
run_quiet helm upgrade --install registry-server oci://ghcr.io/stacklok/toolhive-registry-server --version "$REGISTRY_SERVER_CHART_VERSION" --namespace toolhive-system --values demo-manifests/registry-server-helm-values.yaml --wait || die "Failed to install Registry Server"
run_quiet sh -c "envsubst < demo-manifests/registry-server-httproute.yaml | kubectl apply -f -" || die "Failed to apply Registry Server HTTPRoute"
echo " ✓"

echo -n "Installing Cloud UI..."
run_quiet docker build -t toolhive-cloud-ui-oidc-mock:demo-v1 demo-manifests/oidc-mock || die "Failed to build mock-auth image"
run_quiet kind load docker-image toolhive-cloud-ui-oidc-mock:demo-v1 --name toolhive-demo-in-a-box || die "Failed to load mock-auth image into Kind cluster"
run_quiet sh -c "envsubst < demo-manifests/cloud-ui.yaml | kubectl apply -f -" || die "Failed to install Cloud UI"
echo " ✓"

# Expose Grafana via Traefik, using its own hostname for simplicity
echo -n "Configuring Grafana HTTPRoute..."
run_quiet sh -c "envsubst < infra/grafana-httproute.yaml | kubectl apply -f -" || die "Failed to apply Grafana HTTPRoute"
echo " ✓"

echo -n "Installing MKP MCP server..."
run_quiet sh -c "envsubst < demo-manifests/mcpserver-mkp.yaml | kubectl apply -f -" || die "Failed to install MKP MCP server"
echo " ✓"

echo -n "Installing vMCP demo servers..."
run_quiet kubectl apply -f demo-manifests/vmcp-mcpservers.yaml || die "Failed to apply vMCP MCP servers"
# Wait for vMCP backend MCPServer resources to reach Running phase
run_quiet kubectl wait --for=jsonpath='{.status.phase}'=Running --timeout=5m mcpserver -l demo.toolhive.stacklok.dev/vmcp-backend=true -n toolhive-system || die "vMCP backend MCPServer resources failed to become ready"
run_quiet sh -c "envsubst < demo-manifests/vmcp-demo-simple.yaml | kubectl apply -f -" || die "Failed to apply vMCP demo"
run_quiet sh -c "envsubst < demo-manifests/vmcp-demo-composite.yaml | kubectl apply -f -" || die "Failed to apply vMCP composite tools demo"
# run_quiet sh -c "envsubst < demo-manifests/vmcp-demo-auth.yaml | kubectl apply -f -" || die "Failed to apply vMCP demo with auth"
echo " ✓"

echo -n "Installing MCP Optimizer..."
run_quiet helm upgrade --install mcp-optimizer oci://ghcr.io/stackloklabs/mcp-optimizer/mcp-optimizer \
  --version "$MCP_OPTIMIZER_CHART_VERSION" \
  --values demo-manifests/mcp-optimizer-helm-values.yaml --set "mcpserver.annotations.toolhive\.stacklok\.dev/registry-url=http://${MCP_HOSTNAME}/mcp-optimizer/mcp" \
  --namespace toolhive-system --wait || die "Failed to install MCP Optimizer"
run_quiet sh -c "envsubst < demo-manifests/mcp-optimizer-httproute.yaml | kubectl apply -f -" || die "Failed to apply MCP Optimizer HTTPRoute"
echo " ✓"

echo -n "Waiting for all pods to be ready..."
run_quiet wait_for_pods_ready toolhive-system 300 || die "Pods failed to become ready"
echo " ✓"

# Output endpoint information to JSON file for validation
echo -n "Writing endpoint information to demo-endpoints.json..."
cat > demo-endpoints.json <<EOF
{
  "traefik_ip": "$TRAEFIK_IP",
  "base_hostname": "$TRAEFIK_HOSTNAME_BASE",
  "endpoints": [
    {
      "name": "Cloud UI",
      "url": "https://$UI_HOSTNAME",
      "type": "https",
      "expect_cert_error": true,
      "healthcheck_path": "/"
    },
    {
      "name": "Registry Server",
      "url": "http://$REGISTRY_HOSTNAME",
      "type": "registry",
      "healthcheck_path": "/health",
      "registry_api_path": "/registry/v0.1/servers"
    },
    {
      "name": "MKP MCP Server",
      "url": "http://$MCP_HOSTNAME/mkp/mcp",
      "type": "mcp",
      "test_with_thv": true,
      "healthcheck_path": "/mkp/health"
    },
    {
      "name": "vMCP Demo Server",
      "url": "http://$MCP_HOSTNAME/vmcp-demo/mcp",
      "type": "mcp",
      "test_with_thv": true,
      "healthcheck_path": "/vmcp-demo/health"
    },
    {
      "name": "vMCP Composite Tool Demo Server",
      "url": "http://$MCP_HOSTNAME/vmcp-research/mcp",
      "type": "mcp",
      "test_with_thv": true,
      "healthcheck_path": "/vmcp-research/health"
    },
    {
      "name": "MCP Optimizer",
      "url": "http://$MCP_HOSTNAME/mcp-optimizer/mcp",
      "type": "mcp",
      "test_with_thv": true,
      "healthcheck_path": "/mcp-optimizer/health"
    },
    {
      "name": "Grafana",
      "url": "http://$GRAFANA_HOSTNAME",
      "type": "http",
      "healthcheck_path": "/api/health"
    }
  ]
}
EOF
echo " ✓"

echo "Bootstrap complete! Access your demo services at the following URLs:"
echo " - ToolHive Cloud UI at https://$UI_HOSTNAME (you'll have to accept the self-signed certificate)"
echo " - ToolHive Registry Server at http://$REGISTRY_HOSTNAME/registry"
echo "   (run 'thv config set-registry http://$REGISTRY_HOSTNAME/registry --allow-private-ip' to configure ToolHive to use it)"
echo " - MKP MCP server at http://$MCP_HOSTNAME/mkp/mcp"
echo " - vMCP demo server at http://$MCP_HOSTNAME/vmcp-demo/mcp"
echo " - vMCP composite tool demo server at http://$MCP_HOSTNAME/vmcp-research/mcp"
echo " - MCP Optimizer at http://$MCP_HOSTNAME/mcp-optimizer/mcp"
echo " - Grafana at http://$GRAFANA_HOSTNAME"
