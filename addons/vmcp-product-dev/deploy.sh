#!/bin/bash
. "$(dirname "$0")/../_lib.sh"

addon_load_env
addon_require_env ENTRA_ISSUER_URL
addon_require_env VMCP_ENTRA_CLIENT_ID
addon_require_env VMCP_ENTRA_CLIENT_SECRET
addon_require_env VMCP_PRODUCT_CLOUDFLARED_DOMAIN
addon_require_env VMCP_PRODUCT_CLOUDFLARED_TUNNEL_TOKEN

addon_create_namespace

# Entra ID client secret lives in mcp-workloads alongside the vMCP resource.
# GitLab needs no secret: its client is obtained at runtime via DCR.
echo -n "Creating Entra ID client secret..."
kubectl create secret generic vmcp-product-dev-client-secret \
    --from-literal=client-secret="$VMCP_ENTRA_CLIENT_SECRET" \
    --namespace mcp-workloads \
    --dry-run=client -o yaml | kubectl apply -f - > /dev/null
echo " done"

echo -n "Applying MCPGroup and backends..."
run_quiet addon_apply "$ADDON_DIR/product-dev-tools.yaml"
echo " done"

echo -n "Applying VirtualMCPServer..."
run_quiet addon_apply "$ADDON_DIR/vmcp.yaml"
run_quiet kubectl wait --for=jsonpath='{.status.phase}'=Ready \
    --timeout=3m virtualmcpserver/vmcp-product-dev -n mcp-workloads
echo " done"

echo -n "Creating Cloudflare tunnel token..."
kubectl create secret generic cloudflared-tunnel-token \
    --from-literal=token="$VMCP_PRODUCT_CLOUDFLARED_TUNNEL_TOKEN" \
    --namespace "$ADDON_NAME" \
    --dry-run=client -o yaml | kubectl apply -f - > /dev/null
echo " done"

echo -n "Deploying Cloudflare tunnel..."
run_quiet kubectl apply -f "$ADDON_DIR/cloudflared.yaml"
run_quiet addon_wait_ready app=cloudflared "$ADDON_NAME" 120s
echo " done"

echo ""
echo "vmcp-product-dev is ready!"
echo "  External URL: https://$VMCP_PRODUCT_CLOUDFLARED_DOMAIN/mcp"
echo "  Run:          thv run --name vmcp-product-dev --transport streamable-http https://$VMCP_PRODUCT_CLOUDFLARED_DOMAIN/mcp"
