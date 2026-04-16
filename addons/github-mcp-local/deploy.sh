#!/bin/bash
. "$(dirname "$0")/../_lib.sh"

addon_load_env

# Use gh CLI token if available and GITHUB_PAT not already set
if [ -z "$GITHUB_PAT" ] && command -v gh > /dev/null 2>&1; then
    GITHUB_PAT=$(gh auth token 2>/dev/null || true)
    if [ -n "$GITHUB_PAT" ]; then
        echo "Using token from gh CLI"
    fi
fi

addon_require_env GITHUB_PAT
addon_resolve_traefik

export MCP_HOSTNAME="mcp-${TRAEFIK_HOSTNAME_BASE}"

echo -n "Creating GitHub token secret..."
kubectl create secret generic github-local-token \
    --from-literal=token="$GITHUB_PAT" \
    --namespace toolhive-system \
    --dry-run=client -o yaml | kubectl apply -f - > /dev/null
echo " done"

echo -n "Deploying GitHub MCP server..."
run_quiet addon_apply "$ADDON_DIR/mcpserver.yaml"
echo " done"

echo -n "Waiting for GitHub MCP server..."
run_quiet addon_wait_ready toolhive-name=github-local toolhive-system
echo " done"

echo ""
echo "GitHub MCP server is ready!"
echo "  MCP endpoint: http://$MCP_HOSTNAME/github-local/mcp"
echo "  Mode: read-only"
