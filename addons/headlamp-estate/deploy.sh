#!/bin/bash
. "$(dirname "$0")/../_lib.sh"

addon_load_env
addon_resolve_traefik

export HEADLAMP_ESTATE_HOSTNAME="estate-${TRAEFIK_HOSTNAME_BASE}"
PLUGIN_DIR="$ADDON_DIR/plugin"

addon_create_namespace

echo -n "Building ToolHive Estate Headlamp plugin..."
if [ ! -d "$PLUGIN_DIR/node_modules" ]; then
    (cd "$PLUGIN_DIR" && npm ci > /dev/null)
fi
(cd "$PLUGIN_DIR" && npm run build > /dev/null)
echo " done"

echo -n "Creating plugin ConfigMap..."
kubectl create configmap toolhive-estate-plugin \
    --from-file=main.js="$PLUGIN_DIR/dist/main.js" \
    --from-file=package.json="$PLUGIN_DIR/package.json" \
    --namespace "$ADDON_NAME" \
    --dry-run=client -o yaml | kubectl apply -f - > /dev/null
echo " done"

echo -n "Creating estate API ConfigMap..."
kubectl create configmap toolhive-estate-api \
    --from-file=handler.sh="$ADDON_DIR/estate-api/handler.sh" \
    --namespace "$ADDON_NAME" \
    --dry-run=client -o yaml | kubectl apply -f - > /dev/null
echo " done"

echo -n "Applying read-only RBAC..."
run_quiet addon_apply "$ADDON_DIR/rbac.yaml"
echo " done"

echo -n "Adding Headlamp Helm repo..."
run_quiet helm repo add headlamp https://kubernetes-sigs.github.io/headlamp/ --force-update
echo " done"

echo -n "Installing Headlamp..."
run_quiet helm upgrade --install headlamp-estate headlamp/headlamp \
    --namespace "$ADDON_NAME" \
    --values "$ADDON_DIR/values.yaml" \
    --wait --timeout 5m
echo " done"

echo -n "Applying estate API Service..."
run_quiet addon_apply "$ADDON_DIR/service-api.yaml"
echo " done"

echo -n "Applying HTTPRoute..."
run_quiet addon_apply "$ADDON_DIR/httproute.yaml"
echo " done"

echo -n "Waiting for Headlamp..."
run_quiet addon_wait_ready app.kubernetes.io/instance=headlamp-estate "$ADDON_NAME" 180s
echo " done"

echo -n "Restarting Headlamp to pick up plugin/handler changes..."
run_quiet kubectl rollout restart deployment/headlamp-estate -n "$ADDON_NAME"
run_quiet kubectl rollout status deployment/headlamp-estate -n "$ADDON_NAME" --timeout=2m
echo " done"

echo ""
echo "ToolHive Estate Headlamp addon is ready!"
echo "  URL: http://$HEADLAMP_ESTATE_HOSTNAME/toolhive-estate"
echo "  Scope: read-only ToolHive estate view"
