#!/bin/bash
. "$(dirname "$0")/../_lib.sh"

TEMPO_CHART_VERSION="2.2.0" # renovate: datasource=helm depName=tempo registryUrl=https://grafana-community.github.io/helm-charts

# Tempo lives in the observability namespace alongside the rest of the stack
# so the Grafana datasource and OTel collector resolve `tempo` by short name.
NS="observability"

if ! kubectl get namespace "$NS" >/dev/null 2>&1; then
    die "Namespace $NS not found. Run ./bootstrap.sh first."
fi

echo -n "Adding Helm repo..."
run_quiet helm repo add grafana-community https://grafana-community.github.io/helm-charts 2>/dev/null || true
run_quiet helm repo update grafana-community
echo " done"

echo -n "Installing Tempo (Helm $TEMPO_CHART_VERSION)..."
run_quiet helm upgrade --install tempo grafana-community/tempo \
    --version "$TEMPO_CHART_VERSION" \
    --namespace "$NS" \
    --values "$ADDON_DIR/tempo-helm-values.yaml" \
    --wait
echo " done"

echo -n "Patching OTel collector to export traces to Tempo..."
run_quiet kubectl apply -f "$ADDON_DIR/otel-collector.yaml"
# The OpenTelemetry operator rolls the collector deployment on spec change.
run_quiet kubectl rollout status deployment/mcp-collector -n "$NS" --timeout=120s
echo " done"

echo ""
echo "Tempo is ready!"
echo "  Service:  tempo.observability.svc.cluster.local:4317 (OTLP gRPC)"
echo "  Datasource (already provisioned in Grafana): http://tempo:3200"
echo "  Open Grafana → Explore → Tempo to query traces."
