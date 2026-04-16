#!/bin/bash
. "$(dirname "$0")/../_lib.sh"

addon_load_env
addon_require_env MY_API_KEY          # TODO: replace with your required env vars
addon_resolve_traefik

export MY_HOSTNAME="myapp-${TRAEFIK_HOSTNAME_BASE}"  # TODO: set your hostname

addon_create_namespace

# --- Secrets ---
# TODO: create secrets from env vars
echo -n "Creating secrets..."
kubectl create secret generic myapp-secrets \
    --from-literal=api-key="$MY_API_KEY" \
    --namespace "$ADDON_NAME" \
    --dry-run=client -o yaml | kubectl apply -f - > /dev/null
echo " done"

# --- Deploy ---
# TODO: apply your manifests (addon_apply handles envsubst automatically)
echo -n "Deploying $ADDON_NAME..."
run_quiet kubectl apply -f "$ADDON_DIR/manifests.yaml"
run_quiet addon_apply "$ADDON_DIR/app.yaml"          # use addon_apply for files with $VARS
run_quiet kubectl rollout restart deployment/myapp -n "$ADDON_NAME" 2>/dev/null || true
echo " done"

# --- Wait ---
echo -n "Waiting for $ADDON_NAME..."
run_quiet addon_wait_ready app=myapp "$ADDON_NAME" 180s
echo " done"

# --- Seed (optional) ---
# TODO: any post-deploy seeding (demo users, config, etc.)

echo ""
echo "$ADDON_NAME is ready!"
echo "  URL: http://$MY_HOSTNAME"
