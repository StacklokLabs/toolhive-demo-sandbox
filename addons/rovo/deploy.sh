#!/bin/bash
. "$(dirname "$0")/../_lib.sh"

addon_load_env
addon_require_env ATLASSIAN_CLIENT_ID
addon_require_env ATLASSIAN_CLIENT_SECRET
addon_resolve_traefik

export ROVO_MCP_HOSTNAME="rovo-mcp-${TRAEFIK_HOSTNAME_BASE}"

# --- Deploy manifests ---
echo -n "Deploying Atlassian Rovo MCP Remote Proxy..."
run_quiet addon_apply "$ADDON_DIR/mcpremoteproxy.yaml"
echo " done"

# --- Wait for proxy to be ready ---
echo -n "Waiting for Rovo MCP proxy..."
run_quiet addon_wait_ready app.kubernetes.io/instance=rovo-mcp-proxy toolhive-system 180
echo " done"

echo ""
echo "Atlassian Rovo MCP Remote Proxy is ready!"
echo "  MCP endpoint: https://$ROVO_MCP_HOSTNAME/mcp"
echo "  Auth:         Atlassian OAuth 2.0 → embedded auth server"
echo "  Upstream:     https://mcp.atlassian.com/v1/mcp"
