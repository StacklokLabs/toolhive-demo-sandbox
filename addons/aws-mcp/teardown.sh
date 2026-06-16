#!/bin/bash
. "$(dirname "$0")/../_lib.sh"

echo -n "Removing AWS MCP Remote Proxy..."
kubectl delete mcpremoteproxy aws-mcp-proxy -n mcp-workloads --ignore-not-found > /dev/null 2>&1 || true
kubectl delete mcpoidcconfig aws-mcp-oidc -n mcp-workloads --ignore-not-found > /dev/null 2>&1 || true
kubectl delete mcpexternalauthconfig aws-mcp-eas aws-mcp-sts -n mcp-workloads --ignore-not-found > /dev/null 2>&1 || true
kubectl delete httproute aws-mcp-proxy-route -n mcp-workloads --ignore-not-found > /dev/null 2>&1 || true
echo " done"

echo -n "Removing secrets..."
kubectl delete secret okta-client-secret -n mcp-workloads --ignore-not-found > /dev/null 2>&1
echo " done"

echo "AWS MCP Remote Proxy removed."
