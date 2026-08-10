#!/bin/bash
. "$(dirname "$0")/../_lib.sh"

addon_load_env
addon_resolve_traefik

export BACKSTAGE_HOSTNAME="backstage-${TRAEFIK_HOSTNAME_BASE}"
export BACKSTAGE_IMAGE="${BACKSTAGE_IMAGE:-backstage-toolhive-demo:latest}"
export REGISTRY_HOSTNAME="registry-${TRAEFIK_HOSTNAME_BASE}"
export MCP_HOSTNAME="mcp-${TRAEFIK_HOSTNAME_BASE}"
export GITHUB_TOKEN="${GITHUB_TOKEN:-}"

# Preflight: verify the Backstage image is present in the kind cluster's
# containerd store. The image must be built and loaded manually — see README.md.
_image_name="${BACKSTAGE_IMAGE%%:*}"
if ! docker exec "${CLUSTER_NAME}-control-plane" crictl images --no-trunc 2>/dev/null \
        | grep -qF "$_image_name"; then
    die "Image '${BACKSTAGE_IMAGE}' not found in kind cluster '${CLUSTER_NAME}'.
  Build and load it first — see addons/backstage/README.md for instructions."
fi

# Resolve the registry API service URL.
# The Helm chart typically names the Service "registry-server", but downstream
# forks can use a different fullnameOverride (e.g. "registry-api"). Probe for
# whichever exists so this works without requiring a manual override.
if [ -z "$REGISTRY_SVC_URL" ]; then
    _registry_svc="registry-server"
    if ! kubectl get svc registry-server -n "$RELEASE_NAMESPACE" >/dev/null 2>&1 \
            && kubectl get svc registry-api -n "$RELEASE_NAMESPACE" >/dev/null 2>&1; then
        _registry_svc="registry-api"
    fi
    export REGISTRY_SVC_URL="http://${_registry_svc}.${RELEASE_NAMESPACE}.svc.cluster.local:8080"
fi

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
