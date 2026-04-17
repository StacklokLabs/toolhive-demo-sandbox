#!/bin/bash
. "$(dirname "$0")/../_lib.sh"

echo -n "Removing vmcp-chat VirtualMCPServer..."
kubectl delete -n toolhive-system vmcp/vmcp-chat mcpoidcconfig/vmcp-chat-oidc \
    configmap/vmcp-chat-authz --ignore-not-found > /dev/null 2>&1 || true
echo " done"

echo -n "Removing HTTPRoute..."
kubectl delete -f "$ADDON_DIR/httproute.yaml" --ignore-not-found > /dev/null 2>&1 || true
echo " done"

echo -n "Uninstalling LibreChat (Helm)..."
helm uninstall librechat --namespace librechat > /dev/null 2>&1 || true
echo " done"

echo -n "Removing MongoDB..."
kubectl delete -f "$ADDON_DIR/mongodb.yaml" --ignore-not-found > /dev/null 2>&1 || true
echo " done"

echo -n "Removing secrets..."
kubectl delete secret librechat-credentials -n librechat --ignore-not-found > /dev/null 2>&1
echo " done"

echo -n "Removing PVCs..."
kubectl delete pvc --all -n librechat --ignore-not-found > /dev/null 2>&1
echo " done"

addon_delete_namespace

echo "LibreChat removed."
