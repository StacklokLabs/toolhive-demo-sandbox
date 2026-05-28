#!/bin/bash
. "$(dirname "$0")/../_lib.sh"

# Detect cloud-ui flavor: enterprise Helm chart vs OSS standalone manifest.
if kubectl get deployment stacklok-toolhive-cloud-ui -n "$RELEASE_NAMESPACE" >/dev/null 2>&1; then
    CLOUD_UI_DEPLOYMENT="stacklok-toolhive-cloud-ui"
    CLOUD_UI_CONTAINER="toolhive-cloud-ui"
elif kubectl get deployment cloud-ui -n "$RELEASE_NAMESPACE" >/dev/null 2>&1; then
    CLOUD_UI_DEPLOYMENT="cloud-ui"
    CLOUD_UI_CONTAINER="cloud-ui"
else
    CLOUD_UI_DEPLOYMENT=""
fi

if [ -n "$CLOUD_UI_DEPLOYMENT" ]; then
    echo -n "Removing OpenRouter env from $CLOUD_UI_DEPLOYMENT..."
    kubectl set env deployment/"$CLOUD_UI_DEPLOYMENT" \
        -n "$RELEASE_NAMESPACE" \
        -c "$CLOUD_UI_CONTAINER" \
        OPENROUTER_API_KEY- > /dev/null 2>&1 || true
    echo " done"
fi

echo -n "Removing OpenRouter API key secret..."
kubectl delete secret openrouter-api-key -n "$RELEASE_NAMESPACE" --ignore-not-found > /dev/null 2>&1
echo " done"

echo "OpenRouter removed from Cloud UI."
