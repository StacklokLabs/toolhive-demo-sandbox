#!/bin/bash
. "$(dirname "$0")/../_lib.sh"

echo -n "Removing LibreChat..."
kubectl delete -f "$ADDON_DIR/librechat-app.yaml" --ignore-not-found > /dev/null 2>&1 || true
kubectl delete -f "$ADDON_DIR/librechat.yaml" --ignore-not-found > /dev/null 2>&1
echo " done"

echo -n "Removing MongoDB..."
kubectl delete -f "$ADDON_DIR/mongodb.yaml" --ignore-not-found > /dev/null 2>&1
echo " done"

echo -n "Removing secrets..."
kubectl delete secret librechat-api-keys -n librechat --ignore-not-found > /dev/null 2>&1
echo " done"

echo -n "Removing MongoDB PVC..."
kubectl delete pvc -l app=librechat-mongodb -n librechat --ignore-not-found > /dev/null 2>&1
echo " done"

addon_delete_namespace

echo "LibreChat removed."
