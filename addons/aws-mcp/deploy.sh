#!/bin/bash
. "$(dirname "$0")/../_lib.sh"

addon_load_env
addon_require_env OKTA_DOMAIN
addon_require_env OKTA_CLIENT_ID
addon_require_env OKTA_CLIENT_SECRET
addon_require_env AWS_ACCOUNT_ID
addon_require_env AWS_REGION
addon_resolve_traefik

export AWS_MCP_HOSTNAME="aws-mcp-${TRAEFIK_HOSTNAME_BASE}"

# --- Deploy manifests ---
echo -n "Deploying AWS MCP Remote Proxy..."
run_quiet addon_apply "$ADDON_DIR/mcpremoteproxy.yaml"
echo " done"

# --- Wait for proxy to be ready ---
echo -n "Waiting for AWS MCP proxy..."
run_quiet addon_wait_ready app.kubernetes.io/instance=aws-mcp-proxy toolhive-system 180
echo " done"

echo ""
echo "AWS MCP Remote Proxy is ready!"
echo "  MCP endpoint: https://$AWS_MCP_HOSTNAME/mcp"
echo "  Auth: Okta SSO → embedded auth server → AWS STS"
echo "  Upstream: https://aws-mcp.us-east-1.api.aws/mcp"
