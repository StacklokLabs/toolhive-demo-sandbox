#!/bin/bash
. "$(dirname "$0")/../_lib.sh"

echo -n "Removing Backstage resources..."
kubectl delete -f "$ADDON_DIR/manifests/httproute.yaml" --ignore-not-found > /dev/null 2>&1 || true
kubectl delete -f "$ADDON_DIR/manifests/service.yaml" --ignore-not-found > /dev/null 2>&1 || true
kubectl delete -f "$ADDON_DIR/manifests/deployment.yaml" --ignore-not-found > /dev/null 2>&1 || true
kubectl delete -f "$ADDON_DIR/manifests/configmap.yaml" --ignore-not-found > /dev/null 2>&1 || true
echo " done"

echo -n "Removing RBAC..."
kubectl delete -f "$ADDON_DIR/manifests/clusterrolebinding.yaml" --ignore-not-found > /dev/null 2>&1 || true
kubectl delete -f "$ADDON_DIR/manifests/clusterrole.yaml" --ignore-not-found > /dev/null 2>&1 || true
kubectl delete -f "$ADDON_DIR/manifests/serviceaccount.yaml" --ignore-not-found > /dev/null 2>&1 || true
echo " done"

addon_delete_namespace

echo "Backstage removed."
