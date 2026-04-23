#!/bin/bash
. "$(dirname "$0")/../_lib.sh"

addon_load_env
addon_require_env OKTA_DOMAIN
addon_require_env OKTA_CLIENT_ID
addon_require_env OKTA_CLIENT_SECRET
addon_require_env AWS_ACCOUNT_ID
addon_require_env AWS_REGION
addon_resolve_traefik

export AWS_VMCP_HOSTNAME="aws-vmcp-${TRAEFIK_HOSTNAME_BASE}"

# --- Deploy manifests ---
echo -n "Deploying AWS vMCP..."
run_quiet addon_apply "$ADDON_DIR/manifest.yaml"
echo " done"

# --- Wait for vMCP to be ready ---
echo -n "Waiting for AWS vMCP..."
run_quiet addon_wait_ready app.kubernetes.io/instance=aws-vmcp toolhive-system 180
echo " done"

echo ""
echo "AWS vMCP is ready!"
echo "  MCP endpoint: https://$AWS_VMCP_HOSTNAME/mcp"
echo "  Auth: Okta SSO → embedded auth server → AWS STS"
echo "  Backend: https://aws-mcp.us-east-1.api.aws/mcp (via MCPServerEntry)"
