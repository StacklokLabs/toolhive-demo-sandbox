#!/bin/bash
. "$(dirname "$0")/../_lib.sh"

echo -n "Removing Cloudflare tunnel..."
kubectl delete -f "$ADDON_DIR/cloudflared.yaml" --ignore-not-found > /dev/null 2>&1 || true
echo " done"

echo -n "Removing VirtualMCPServer..."
kubectl delete virtualmcpserver vmcp-infra-okta -n mcp-workloads --ignore-not-found > /dev/null 2>&1 || true
kubectl delete mcpoidcconfig vmcp-infra-okta-oidc -n mcp-workloads --ignore-not-found > /dev/null 2>&1 || true
echo " done"

echo -n "Removing secrets..."
kubectl delete secret vmcp-infra-okta-client-secret -n mcp-workloads --ignore-not-found > /dev/null 2>&1
kubectl delete secret cloudflared-tunnel-token -n "$ADDON_NAME" --ignore-not-found > /dev/null 2>&1
echo " done"

addon_delete_namespace

echo "vmcp-infra-okta removed."
