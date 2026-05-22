#!/bin/bash
. "$(dirname "$0")/../_lib.sh"

NS="observability"

echo -n "Reverting OTel collector to core (no Tempo exporter)..."
if [ -f "$REPO_ROOT/infra/otel-collector.yaml" ]; then
    run_quiet kubectl apply -f "$REPO_ROOT/infra/otel-collector.yaml"
    run_quiet kubectl rollout status deployment/mcp-collector -n "$NS" --timeout=120s 2>/dev/null || true
fi
echo " done"

echo -n "Uninstalling Tempo..."
run_quiet helm uninstall tempo --namespace "$NS" 2>/dev/null || true
echo " done"

echo -n "Removing Tempo PVCs..."
run_quiet kubectl delete pvc -l app.kubernetes.io/instance=tempo -n "$NS" --ignore-not-found
echo " done"

echo "Tempo addon removed. Traces sent to the OTel collector are dropped (debug exporter only)."
