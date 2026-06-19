#!/bin/bash
. "$(dirname "$0")/../_lib.sh"

addon_load_env
addon_resolve_traefik

export BACKSTAGE_HOSTNAME="backstage-${TRAEFIK_HOSTNAME_BASE}"
export BACKSTAGE_IMAGE="${BACKSTAGE_IMAGE:-backstage-toolhive-demo:latest}"
export REGISTRY_HOSTNAME="registry-${TRAEFIK_HOSTNAME_BASE}"
export GITHUB_TOKEN="${GITHUB_TOKEN:-}"

# --- Namespace + RBAC ---
echo -n "Creating namespace and RBAC..."
run_quiet kubectl apply -f "$ADDON_DIR/manifests/namespace.yaml"
run_quiet kubectl apply -f "$ADDON_DIR/manifests/serviceaccount.yaml"
run_quiet kubectl apply -f "$ADDON_DIR/manifests/clusterrole.yaml"
run_quiet kubectl apply -f "$ADDON_DIR/manifests/clusterrolebinding.yaml"
echo " done"

# --- ConfigMap (with envsubst for hostnames) ---
echo -n "Creating app config..."
run_quiet addon_apply "$ADDON_DIR/manifests/configmap.yaml"
echo " done"

# --- Deploy ---
echo -n "Deploying Backstage..."
run_quiet addon_apply "$ADDON_DIR/manifests/deployment.yaml"
run_quiet addon_apply "$ADDON_DIR/manifests/service.yaml"
run_quiet addon_apply "$ADDON_DIR/manifests/httproute.yaml"
echo " done"

# --- Wait ---
echo -n "Waiting for Backstage to be ready..."
run_quiet addon_wait_ready app=backstage backstage 180
echo " done"

echo ""
echo "Backstage is ready!"
echo "  URL: http://$BACKSTAGE_HOSTNAME"
echo "  MCP Servers: http://$BACKSTAGE_HOSTNAME/toolhive"
echo "  Registry Browser: http://$BACKSTAGE_HOSTNAME/toolhive/registry"
echo "  Software Templates: http://$BACKSTAGE_HOSTNAME/create"
