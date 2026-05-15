#!/bin/bash
. "$(dirname "$0")/../_lib.sh"

addon_load_env

echo -n "Uninstalling Headlamp Estate Helm release..."
helm uninstall headlamp-estate --namespace "$ADDON_NAME" > /dev/null 2>&1 || true
echo " done"

echo -n "Removing estate API Service..."
kubectl delete service headlamp-estate-api --namespace "$ADDON_NAME" --ignore-not-found > /dev/null
echo " done"

echo -n "Removing cluster-scoped RBAC..."
kubectl delete clusterrolebinding headlamp-estate-readonly --ignore-not-found > /dev/null
kubectl delete clusterrole headlamp-estate-readonly --ignore-not-found > /dev/null
echo " done"

addon_delete_namespace

echo ""
echo "Headlamp Estate addon removed."
