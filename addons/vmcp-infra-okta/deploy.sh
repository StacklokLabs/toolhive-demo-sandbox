#!/bin/bash
. "$(dirname "$0")/../_lib.sh"

addon_load_env
addon_require_env OKTA_ISSUER_URL
addon_require_env VMCP_OKTA_CLIENT_ID
addon_require_env VMCP_OKTA_CLIENT_SECRET
addon_require_env VMCP_OKTA_CLOUDFLARED_DOMAIN
addon_require_env VMCP_OKTA_CLOUDFLARED_TUNNEL_TOKEN

addon_create_namespace

# Okta client secret lives in toolhive-system alongside the vMCP resource.
echo -n "Creating Okta client secret..."
kubectl create secret generic vmcp-infra-okta-client-secret \
    --from-literal=client-secret="$VMCP_OKTA_CLIENT_SECRET" \
    --namespace toolhive-system \
    --dry-run=client -o yaml | kubectl apply -f - > /dev/null
echo " done"

echo -n "Applying VirtualMCPServer..."
run_quiet addon_apply "$ADDON_DIR/vmcp.yaml"
run_quiet kubectl wait --for=jsonpath='{.status.phase}'=Ready \
    --timeout=3m virtualmcpserver/vmcp-infra-okta -n toolhive-system
echo " done"

echo -n "Creating Cloudflare tunnel token..."
kubectl create secret generic cloudflared-tunnel-token \
    --from-literal=token="$VMCP_OKTA_CLOUDFLARED_TUNNEL_TOKEN" \
    --namespace "$ADDON_NAME" \
    --dry-run=client -o yaml | kubectl apply -f - > /dev/null
echo " done"

echo -n "Deploying Cloudflare tunnel..."
run_quiet kubectl apply -f "$ADDON_DIR/cloudflared.yaml"
run_quiet addon_wait_ready app=cloudflared "$ADDON_NAME" 120s
echo " done"

echo ""
echo "vmcp-infra-okta is ready!"
echo "  External URL: https://$VMCP_OKTA_CLOUDFLARED_DOMAIN/mcp"
echo "  Run:          thv run --name vmcp-infra-okta --transport streamable-http https://$VMCP_OKTA_CLOUDFLARED_DOMAIN/mcp"
