#!/bin/bash
. "$(dirname "$0")/../_lib.sh"

echo -n "Removing Atlassian Rovo MCP Remote Proxy..."
kubectl delete mcpremoteproxy rovo-mcp-proxy -n mcp-workloads --ignore-not-found > /dev/null 2>&1 || true
kubectl delete mcpoidcconfig rovo-mcp-oidc -n mcp-workloads --ignore-not-found > /dev/null 2>&1 || true
kubectl delete mcpexternalauthconfig rovo-mcp-eas -n mcp-workloads --ignore-not-found > /dev/null 2>&1 || true
kubectl delete httproute rovo-mcp-proxy-route -n mcp-workloads --ignore-not-found > /dev/null 2>&1 || true
echo " done"

echo "Atlassian Rovo MCP Remote Proxy removed."
