#!/bin/bash
. "$(dirname "$0")/../_lib.sh"

addon_load_env
addon_require_env OPENROUTER_API_KEY

# Detect cloud-ui flavor: enterprise Helm chart vs OSS standalone manifest.
if kubectl get deployment stacklok-toolhive-cloud-ui -n "$RELEASE_NAMESPACE" >/dev/null 2>&1; then
    CLOUD_UI_DEPLOYMENT="stacklok-toolhive-cloud-ui"
    CLOUD_UI_CONTAINER="toolhive-cloud-ui"
elif kubectl get deployment cloud-ui -n "$RELEASE_NAMESPACE" >/dev/null 2>&1; then
    CLOUD_UI_DEPLOYMENT="cloud-ui"
    CLOUD_UI_CONTAINER="cloud-ui"
else
    die "No cloud-ui deployment found in namespace $RELEASE_NAMESPACE (tried stacklok-toolhive-cloud-ui and cloud-ui). Has bootstrap.sh completed?"
fi
export CLOUD_UI_CONTAINER

echo -n "Creating OpenRouter API key secret..."
kubectl create secret generic openrouter-api-key \
    --from-literal=api-key="$OPENROUTER_API_KEY" \
    --namespace "$RELEASE_NAMESPACE" \
    --dry-run=client -o yaml | kubectl apply -f - > /dev/null
echo " done"

echo -n "Patching $CLOUD_UI_DEPLOYMENT deployment..."
kubectl patch deployment "$CLOUD_UI_DEPLOYMENT" \
    -n "$RELEASE_NAMESPACE" \
    --type=strategic \
    --patch "$(envsubst '$CLOUD_UI_CONTAINER' < "$ADDON_DIR/patch.yaml")" > /dev/null
echo " done"

echo ""
echo "Cloud UI now has OpenRouter access. It will restart automatically."
