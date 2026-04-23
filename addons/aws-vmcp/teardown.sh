#!/bin/bash
. "$(dirname "$0")/../_lib.sh"

echo -n "Removing AWS vMCP..."
kubectl delete virtualmcpserver aws-vmcp -n toolhive-system --ignore-not-found > /dev/null 2>&1 || true
kubectl delete mcpserverentry aws-mcp -n toolhive-system --ignore-not-found > /dev/null 2>&1 || true
kubectl delete mcpoidcconfig aws-vmcp-oidc -n toolhive-system --ignore-not-found > /dev/null 2>&1 || true
kubectl delete mcpexternalauthconfig aws-vmcp-sts -n toolhive-system --ignore-not-found > /dev/null 2>&1 || true
kubectl delete mcpgroup aws-vmcp-tools -n toolhive-system --ignore-not-found > /dev/null 2>&1 || true
kubectl delete httproute aws-vmcp-route -n toolhive-system --ignore-not-found > /dev/null 2>&1 || true
echo " done"

echo -n "Removing secrets..."
kubectl delete secret aws-vmcp-okta-client-secret -n toolhive-system --ignore-not-found > /dev/null 2>&1
echo " done"

echo "AWS vMCP removed."
