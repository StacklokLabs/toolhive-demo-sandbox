#!/bin/bash
. "$(dirname "$0")/../_lib.sh"

addon_load_env
addon_require_env OPENROUTER_API_KEY

echo -n "Creating OpenRouter API key secret..."
kubectl create secret generic openrouter-api-key \
    --from-literal=api-key="$OPENROUTER_API_KEY" \
    --namespace "$RELEASE_NAMESPACE" \
    --dry-run=client -o yaml | kubectl apply -f - > /dev/null
echo " done"

echo -n "Patching cloud-ui deployment..."
kubectl patch deployment cloud-ui \
    -n "$RELEASE_NAMESPACE" \
    --type=strategic \
    --patch-file="$ADDON_DIR/patch.yaml" > /dev/null
echo " done"

echo ""
echo "Cloud UI now has OpenRouter access. It will restart automatically."
