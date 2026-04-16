#!/bin/bash
. "$(dirname "$0")/../_lib.sh"

echo -n "Removing OpenRouter env from cloud-ui..."
# Remove the OPENROUTER_API_KEY env var by patching it out
kubectl patch deployment cloud-ui \
    -n toolhive-system \
    --type=json \
    -p='[{"op":"remove","path":"/spec/template/spec/containers/0/env/-"}]' > /dev/null 2>&1 || true
echo " done"

echo -n "Removing OpenRouter API key secret..."
kubectl delete secret openrouter-api-key -n toolhive-system --ignore-not-found > /dev/null 2>&1
echo " done"

echo "OpenRouter removed from Cloud UI."
