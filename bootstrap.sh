#!/bin/bash
set -e
set -a  # automatically export all variables for subshells

# Bootstrap script for the ToolHive demo sandbox Kubernetes cluster.

## Requirements:
# - kind
# - kubectl
# - helm

# Chart/image pins and cluster identity live in versions.env
. "$(dirname "$0")/versions.env"

# Select the text-embeddings-inference image variant that matches the host arch.
# Used by the optimizer-enabled vMCP gateways.
case "$(uname -m)" in
    arm64|aarch64) EMBEDDING_IMAGE="ghcr.io/huggingface/text-embeddings-inference:cpu-arm64-latest" ;;
    *)             EMBEDDING_IMAGE="ghcr.io/huggingface/text-embeddings-inference:cpu-latest" ;;
esac

# Source common helper functions
. "$(dirname "$0")/scripts/helpers.sh"

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

# Check that sslip.io wildcard DNS resolves. The demo's hostnames
# (auth/registry/ui/grafana/mcp) are all served from *.sslip.io, so an
# outage of that service makes the demo unusable from a browser even though
# the cluster will still bootstrap. Warn-and-continue rather than hard-fail
# so users with a /etc/hosts override or offline-only goals can still proceed.
echo -n "  Checking sslip.io DNS resolution..."
SSLIP_IO_PROBE=$(getent hosts 1-2-3-4.sslip.io 2>/dev/null | awk '{print $1}' || true)
if [ -z "$SSLIP_IO_PROBE" ]; then
    SSLIP_IO_PROBE=$(dig +short +time=2 +tries=1 1-2-3-4.sslip.io 2>/dev/null | head -n1 || true)
fi
if [ "$SSLIP_IO_PROBE" = "1.2.3.4" ]; then
    echo " ✓"
else
    echo " ⚠"
    echo "    sslip.io did not resolve (expected 1-2-3-4.sslip.io → 1.2.3.4, got '${SSLIP_IO_PROBE:-empty}')."
    echo "    The cluster will still bootstrap, but Cloud UI / Keycloak / registry"
    echo "    will be unreachable by hostname until DNS is restored or you add"
    echo "    /etc/hosts entries for *-<traefik-ip-with-dashes>.sslip.io."
fi

# Load environment variables from .env if it exists
if [ -f "$(dirname "$0")/.env" ]; then
    source "$(dirname "$0")/.env"
fi

echo -n "Creating Kind cluster..."
if kind get clusters 2>/dev/null | grep -q "^${CLUSTER_NAME}$"; then
    echo " (already exists, skipping)"
else
    run_quiet kind create cluster --config "$(dirname "$0")/kind-config.yaml" || die "Failed to create Kind cluster"
    echo " ✓"
fi
run_quiet sh -c "kind get kubeconfig --name ${CLUSTER_NAME} > ${KUBECONFIG_FILE}" || die "Failed to get kubeconfig"
export KUBECONFIG=$(pwd)/${KUBECONFIG_FILE}

# Traefik chart no longer installs the Gateway API CRDs by default, so install them up front to ensure they're available before Traefik lands
echo -n "Installing Gateway API..."
run_quiet kubectl apply --server-side -f https://github.com/kubernetes-sigs/gateway-api/releases/download/${GATEWAY_API_VERSION}/standard-install.yaml || die "Failed to install Gateway API"
echo " ✓"

# Add Helm repos and update
echo -n "Adding Helm repositories..."
run_quiet helm repo add traefik https://traefik.github.io/charts || die "Failed to add Traefik repo"
run_quiet helm repo add grafana-community https://grafana-community.github.io/helm-charts || die "Failed to add Grafana Community repo"
run_quiet helm repo add prometheus-community https://prometheus-community.github.io/helm-charts || die "Failed to add Prometheus repo"
run_quiet helm repo add fluent https://fluent.github.io/helm-charts || die "Failed to add Fluent repo"
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
# Tempo is opt-in via the observability-tempo addon. The core OTel collector
# accepts traces but drops them; install the addon to wire up real tracing.
run_quiet helm upgrade --install loki grafana-community/loki --version "$LOKI_CHART_VERSION" --namespace observability --values infra/loki-helm-values.yaml --wait || die "Failed to install Loki"
run_quiet helm upgrade --install prometheus prometheus-community/prometheus --version "$PROMETHEUS_CHART_VERSION" --namespace observability --values infra/prometheus-helm-values.yaml --wait || die "Failed to install Prometheus"
run_quiet helm upgrade --install grafana grafana-community/grafana --version "$GRAFANA_CHART_VERSION" --namespace observability --values infra/grafana-helm-values.yaml --set-file dashboards.default.mcp-observability.json=infra/grafana-dashboard-mcp.json --set-file dashboards.default.toolhive-audit-log.json=infra/grafana-dashboard-audit.json --set-file dashboards.default.toolhive-registry.json=infra/grafana-dashboard-registry.json --wait || die "Failed to install Grafana"
run_quiet kubectl apply -f infra/otel-collector.yaml || die "Failed to apply OTel collector config"
run_quiet helm upgrade --install fluent-bit fluent/fluent-bit --version "$FLUENT_BIT_CHART_VERSION" --namespace observability --values infra/fluent-bit-helm-values.yaml --wait || die "Failed to install Fluent Bit"
echo " ✓"

# Reference: https://docs.stacklok.com/toolhive/tutorials/quickstart-k8s
echo -n "Installing ToolHive Operator..."
run_quiet helm upgrade --install toolhive-operator-crds oci://ghcr.io/stacklok/toolhive/toolhive-operator-crds --version "$TOOLHIVE_OPERATOR_CRDS_CHART_VERSION" --namespace "$RELEASE_NAMESPACE" --create-namespace --wait || die "Failed to install ToolHive Operator CRDs"
run_quiet helm upgrade --install toolhive-operator oci://ghcr.io/stacklok/toolhive/toolhive-operator --version "$TOOLHIVE_OPERATOR_CHART_VERSION" --namespace "$RELEASE_NAMESPACE" --create-namespace --wait || die "Failed to install ToolHive Operator"
echo " ✓"

# Check if traefik gateway already has an IP assigned
echo -n "Checking for Traefik Gateway IP..."
TRAEFIK_IP=$(kubectl get gateways --namespace traefik traefik-gateway -o "jsonpath={.status.addresses[0].value}" 2>/dev/null || echo "")

if [ -z "$TRAEFIK_IP" ]; then
    echo " (no IP yet)"
    # Only prompt when attached to a terminal. In CI (e.g. the ARC runner) stdin
    # is not a TTY, so read would hit EOF, return non-zero, and trip set -e with a
    # confusing instant exit. Skipping straight to the wait loop lets the timeout
    # below surface the honest "Is cloud-provider-kind running?" message instead.
    if [ -t 0 ]; then
        echo ""
        read -p "Run 'sudo cloud-provider-kind --gateway-channel disabled' in another terminal to assign an IP to the traefik gateway. Press Enter to continue once running..."
    fi

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

TRAEFIK_HOSTNAME_BASE="${TRAEFIK_IP//./-}.sslip.io"
export MCP_HOSTNAME="mcp-${TRAEFIK_HOSTNAME_BASE}"
export REGISTRY_HOSTNAME="registry-${TRAEFIK_HOSTNAME_BASE}"
export UI_HOSTNAME="ui-${TRAEFIK_HOSTNAME_BASE}"
export AUTH_HOSTNAME="auth-${TRAEFIK_HOSTNAME_BASE}"
export GRAFANA_HOSTNAME="grafana-${TRAEFIK_HOSTNAME_BASE}"

echo -n "Installing Keycloak..."
if ! namespace_exists keycloak; then
    run_quiet kubectl create namespace keycloak || die "Failed to create keycloak namespace"
fi
# Keycloak uses dev-file (H2 on disk) with a PVC, so signing keys and realm
# data persist across restarts. The --import-realm flag is a no-op once the
# realm exists, so re-runs are normally safe. Exception: client redirect URIs
# are hostname-based and baked in at import time. If the Traefik LB IP
# changes between bootstraps (e.g. cloud-provider-kind hands out a different
# address after a docker restart), the persisted URIs go stale and every
# OIDC callback fails with "Invalid redirect URI". Detect that drift against
# a stamped ConfigMap and wipe the PVC so the fresh pod re-imports.
PREVIOUS_BASE=$(kubectl get configmap keycloak-bootstrap-state -n keycloak \
    -o jsonpath='{.data.traefikHostnameBase}' 2>/dev/null || true)
if [ -n "$PREVIOUS_BASE" ] && [ "$PREVIOUS_BASE" != "$TRAEFIK_HOSTNAME_BASE" ]; then
    echo ""
    echo " Traefik LB IP changed ($PREVIOUS_BASE → $TRAEFIK_HOSTNAME_BASE); resetting Keycloak realm data..."
    run_quiet kubectl delete deployment keycloak -n keycloak --ignore-not-found
    run_quiet kubectl delete pvc keycloak-h2-data -n keycloak --ignore-not-found
    echo -n " Reinstalling Keycloak..."
fi
run_quiet sh -c "envsubst '\$KEYCLOAK_VERSION \$UI_HOSTNAME \$AUTH_HOSTNAME' < infra/keycloak.yaml | kubectl apply -f -" || die "Failed to install Keycloak"
run_quiet wait_for_pods_ready keycloak 300 || die "Keycloak failed to become ready"
# Stamp the bootstrap state so the next re-bootstrap can detect IP drift.
run_quiet sh -c "kubectl create configmap keycloak-bootstrap-state -n keycloak \
    --from-literal=traefikHostnameBase='$TRAEFIK_HOSTNAME_BASE' \
    --dry-run=client -o yaml | kubectl apply -f -" || die "Failed to stamp Keycloak bootstrap state"
echo " ✓"

echo -n "Installing PostgreSQL (registry DB)..."
run_quiet helm upgrade --install cloudnative-pg cnpg/cloudnative-pg --version "$CLOUDNATIVE_PG_CHART_VERSION" --namespace cnpg-system --create-namespace --wait || die "Failed to install CloudNativePG Operator"
run_quiet sh -c "envsubst '\$RELEASE_NAMESPACE' < infra/registry-server-db.yaml | kubectl apply -f -" || die "Failed to create PostgreSQL cluster for registry DB"
run_quiet kubectl wait --for=condition=Ready cluster/registry-db -n "$RELEASE_NAMESPACE" --timeout=5m || die "PostgreSQL cluster failed to become ready"
echo " ✓"

echo -n "Creating Traefik CA ConfigMap for registry server TLS verification..."
run_quiet sh -c "kubectl get secret sslip-io-tls -n traefik -o jsonpath='{.data.ca\\.crt}' | base64 -d | kubectl create configmap traefik-ca -n $RELEASE_NAMESPACE --from-file=ca.crt=/dev/stdin --dry-run=client -o yaml | kubectl apply -f -" || die "Failed to create Traefik CA ConfigMap"
echo " ✓"

# MCP/vMCP/MCPGroup workloads live in their own namespace so the operator
# and registry server (in $RELEASE_NAMESPACE) stay decoupled from user
# workloads. The operator watches cluster-wide and the registry's K8s
# source defaults to all namespaces, so this split needs no further config.
echo -n "Creating mcp-workloads namespace..."
if ! namespace_exists mcp-workloads; then
    run_quiet kubectl create namespace mcp-workloads || die "Failed to create mcp-workloads namespace"
fi
echo " ✓"

# Install all MCP resources before the Registry Server so its K8s reconciler
# and git-source syncs run against a steady state — otherwise the burst of
# reconcile events during initial MCPServer/VirtualMCPServer readiness races
# with git-source commits on the same serializable transactions and trips
# SQLSTATE 40001 conflicts, sometimes starving sources out entirely.

echo -n "Applying shared MCPTelemetryConfig..."
run_quiet kubectl apply -f demo-manifests/mcp-telemetry-config.yaml || die "Failed to apply MCPTelemetryConfig resources"
echo " ✓"

echo -n "Applying persona MCPGroups + backends..."
run_quiet kubectl apply -f demo-manifests/infra-tools.yaml || die "Failed to apply infra-tools group"
run_quiet kubectl apply -f demo-manifests/shared-tools.yaml || die "Failed to apply shared-tools group"
run_quiet kubectl apply -f demo-manifests/finance-tools.yaml || die "Failed to apply finance-tools group"
run_quiet sh -c "envsubst < demo-manifests/mcpserver-mkp.yaml | kubectl apply -f -" || die "Failed to install MKP MCP server"
# Wait for backend MCPServer and MCPRemoteProxy resources to reach Ready phase
run_quiet kubectl wait --for=jsonpath='{.status.phase}'=Ready --timeout=5m mcpserver -l demo.toolhive.stacklok.dev/vmcp-backend=true -n mcp-workloads || die "vMCP backend MCPServer resources failed to become ready"
run_quiet kubectl wait --for=jsonpath='{.status.phase}'=Ready --timeout=5m mcpremoteproxy -l demo.toolhive.stacklok.dev/vmcp-backend=true -n mcp-workloads || die "vMCP backend MCPRemoteProxy resources failed to become ready"
echo " ✓"

echo -n "Applying optimizer EmbeddingServer ($EMBEDDING_IMAGE)..."
run_quiet sh -c "envsubst < demo-manifests/embedding-server.yaml | kubectl apply -f -" || die "Failed to apply embedding server"
run_quiet kubectl wait --for=jsonpath='{.status.phase}'=Ready --timeout=10m embeddingserver/optimizer-embedding -n mcp-workloads || die "EmbeddingServer failed to become ready"
echo " ✓"

echo -n "Applying persona VirtualMCPServer gateways..."
run_quiet sh -c "envsubst < demo-manifests/vmcp-infra.yaml | kubectl apply -f -" || die "Failed to apply vmcp-infra"
run_quiet sh -c "envsubst < demo-manifests/vmcp-infra-optimized.yaml | kubectl apply -f -" || die "Failed to apply vmcp-infra-optimized"
run_quiet sh -c "envsubst < demo-manifests/vmcp-docs.yaml | kubectl apply -f -" || die "Failed to apply vmcp-docs"
run_quiet sh -c "envsubst < demo-manifests/vmcp-finance.yaml | kubectl apply -f -" || die "Failed to apply vmcp-finance"
run_quiet sh -c "envsubst < demo-manifests/vmcp-platform.yaml | kubectl apply -f -" || die "Failed to apply vmcp-platform"
echo " ✓"

# Clean up any prior Helm-managed Registry Server release — the operator-managed
# MCPRegistry below replaces it. No-op on fresh clusters or clusters already
# migrated.
run_quiet sh -c "helm -n $RELEASE_NAMESPACE uninstall registry-server 2>/dev/null || true"

echo -n "Applying MCPRegistry (registry server)..."
run_quiet sh -c "envsubst '\$REGISTRY_HOSTNAME \$AUTH_HOSTNAME \$REGISTRY_SERVER_VERSION \$RELEASE_NAMESPACE \$KC_REALM \$REGISTRY_RESOURCE_NAME' < demo-manifests/registry-server-mcpregistry.yaml | kubectl apply -f -" || die "Failed to apply MCPRegistry"
run_quiet kubectl -n "$RELEASE_NAMESPACE" wait --for=condition=Ready --timeout=5m mcpregistry/"$REGISTRY_RESOURCE_NAME" || die "MCPRegistry failed to become ready"
echo " ✓"

echo -n "Applying Cloud UI..."
run_quiet sh -c "envsubst < demo-manifests/cloud-ui.yaml | kubectl apply -f -" || die "Failed to install Cloud UI"
echo " ✓"

# Expose Grafana via Traefik, using its own hostname for simplicity
echo -n "Configuring Grafana HTTPRoute..."
run_quiet sh -c "envsubst < infra/grafana-httproute.yaml | kubectl apply -f -" || die "Failed to apply Grafana HTTPRoute"
echo " ✓"

echo -n "Waiting for all pods to be ready..."
run_quiet wait_for_pods_ready "$RELEASE_NAMESPACE" 300 || die "Pods in $RELEASE_NAMESPACE failed to become ready"
run_quiet wait_for_pods_ready mcp-workloads 300 || die "Pods in mcp-workloads failed to become ready"
echo " ✓"

# Validate registry by fetching a token and querying the server list
echo -n "Validating registry server..."
# `|| true` guards: with set -e, a $(...) assignment whose pipeline exits
# non-zero (e.g. curl can't resolve the host, python3 fails on empty stdin)
# would terminate the script silently before the empty-string fallbacks below
# could run.
REGISTRY_TOKEN=$(curl -sk -X POST "https://${AUTH_HOSTNAME}/realms/${KC_REALM}/protocol/openid-connect/token" \
    -d "grant_type=password&client_id=toolhive-cloud-ui&client_secret=cloud-ui-secret-change-in-production&username=demo&password=demo&scope=openid" \
    2>/dev/null | python3 -c "import sys,json; print(json.load(sys.stdin).get('access_token',''))" 2>/dev/null) || true
if [ -z "$REGISTRY_TOKEN" ]; then
    echo " ⚠ (could not obtain token from Keycloak — registry validation skipped)"
else
    SERVER_COUNT=$(curl -s "http://${REGISTRY_HOSTNAME}/registry/demo-registry/v0.1/servers?limit=100" \
        -H "Authorization: Bearer ${REGISTRY_TOKEN}" 2>/dev/null \
        | python3 -c "import sys,json; d=json.load(sys.stdin); print(len(set(s.get('server',{}).get('name','') for s in d.get('servers',[]))))" 2>/dev/null) || true
    if [ -n "$SERVER_COUNT" ] && [ "$SERVER_COUNT" -gt 0 ] 2>/dev/null; then
        echo " ✓ ($SERVER_COUNT unique servers detected)"
    else
        echo " ⚠ (registry returned no servers — sources may still be syncing)"
    fi
fi

# Output endpoint information to JSON file for validation
echo -n "Writing endpoint information to demo-endpoints.json..."
cat > demo-endpoints.json <<EOF
{
  "traefik_ip": "$TRAEFIK_IP",
  "base_hostname": "$TRAEFIK_HOSTNAME_BASE",
  "endpoints": [
    {
      "name": "Keycloak",
      "url": "https://$AUTH_HOSTNAME",
      "type": "https",
      "expect_cert_error": true,
      "healthcheck_path": "/realms/$KC_REALM/.well-known/openid-configuration"
    },
    {
      "name": "Grafana",
      "url": "http://$GRAFANA_HOSTNAME",
      "type": "http",
      "healthcheck_path": "/api/health"
    },
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
      "registry_api_path": "/registry/demo-registry/v0.1/servers"
    },
    {
      "name": "MKP MCP Server",
      "url": "http://$MCP_HOSTNAME/mkp/mcp",
      "type": "mcp",
      "test_with_thv": true,
      "healthcheck_path": "/mkp/health"
    },
    {
      "name": "vMCP Infra Gateway",
      "url": "http://$MCP_HOSTNAME/vmcp-infra/mcp",
      "type": "mcp",
      "test_with_thv": true,
      "healthcheck_path": "/vmcp-infra/health"
    },
    {
      "name": "vMCP Infra Gateway (Optimized)",
      "url": "http://$MCP_HOSTNAME/vmcp-infra-optimized/mcp",
      "type": "mcp",
      "test_with_thv": true,
      "healthcheck_path": "/vmcp-infra-optimized/health"
    },
    {
      "name": "vMCP Docs Gateway",
      "url": "http://$MCP_HOSTNAME/vmcp-docs/mcp",
      "type": "mcp",
      "test_with_thv": true,
      "healthcheck_path": "/vmcp-docs/health"
    },
    {
      "name": "vMCP Finance Gateway",
      "url": "http://$MCP_HOSTNAME/vmcp-finance/mcp",
      "type": "mcp",
      "test_with_thv": true,
      "healthcheck_path": "/vmcp-finance/health"
    },
    {
      "name": "vMCP Platform-Ops Gateway",
      "url": "http://$MCP_HOSTNAME/vmcp-platform/mcp",
      "type": "mcp",
      "test_with_thv": true,
      "healthcheck_path": "/vmcp-platform/health"
    }
  ]
}
EOF
echo " ✓"

echo ""
echo "Bootstrap complete."
echo ""
echo "User-facing endpoints:"
echo "  Cloud UI:               https://$UI_HOSTNAME  (self-signed cert)"
echo "  Keycloak admin:         https://$AUTH_HOSTNAME/admin  (admin/admin)"
echo "  Registry (auth):        http://$REGISTRY_HOSTNAME/registry/demo-registry"
echo "  Registry (public):      http://$REGISTRY_HOSTNAME/registry/public"
echo "  MKP MCP server:         http://$MCP_HOSTNAME/mkp/mcp"
echo "  vMCP gateways:          http://$MCP_HOSTNAME/{vmcp-infra,vmcp-infra-optimized,vmcp-docs,vmcp-finance,vmcp-platform}/mcp"
echo "  Grafana:                http://$GRAFANA_HOSTNAME"
echo ""
echo "Demo users in the $KC_REALM realm:"
echo "  demo  / demo   - admin persona (registry superAdmin, sees all tools)"
echo "  alice / alice  - engineering persona"
echo "  bob   / bob    - finance persona"
echo ""
echo "Point thv at the public registry (no auth):"
echo "  thv config set-registry http://$REGISTRY_HOSTNAME/registry/public --allow-private-ip"
