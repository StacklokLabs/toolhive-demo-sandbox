#!/bin/bash
. "$(dirname "$0")/../_lib.sh"

echo -n "Removing Atlassian Rovo MCP Remote Proxy..."
kubectl delete mcpremoteproxy rovo-mcp-proxy -n toolhive-system --ignore-not-found > /dev/null 2>&1 || true
kubectl delete mcpoidcconfig rovo-mcp-oidc -n toolhive-system --ignore-not-found > /dev/null 2>&1 || true
kubectl delete mcpexternalauthconfig rovo-mcp-eas -n toolhive-system --ignore-not-found > /dev/null 2>&1 || true
kubectl delete httproute rovo-mcp-proxy-route -n toolhive-system --ignore-not-found > /dev/null 2>&1 || true
echo " done"

echo -n "Removing secrets..."
kubectl delete secret atlassian-client-secret -n toolhive-system --ignore-not-found > /dev/null 2>&1
echo " done"

echo "Atlassian Rovo MCP Remote Proxy removed."
