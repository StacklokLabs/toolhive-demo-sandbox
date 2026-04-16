#!/bin/bash
. "$(dirname "$0")/../_lib.sh"

# TODO: delete your resources in reverse order
echo -n "Removing $ADDON_NAME..."
kubectl delete -f "$ADDON_DIR/app.yaml" --ignore-not-found > /dev/null 2>&1 || true
kubectl delete -f "$ADDON_DIR/manifests.yaml" --ignore-not-found > /dev/null 2>&1 || true
echo " done"

echo -n "Removing secrets..."
kubectl delete secret myapp-secrets -n "$ADDON_NAME" --ignore-not-found > /dev/null 2>&1
echo " done"

# TODO: remove PVCs if your addon uses persistent storage
# echo -n "Removing PVCs..."
# kubectl delete pvc -l app=myapp -n "$ADDON_NAME" --ignore-not-found > /dev/null 2>&1
# echo " done"

addon_delete_namespace

echo "$ADDON_NAME removed."
