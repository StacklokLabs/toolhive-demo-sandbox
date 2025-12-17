#!/bin/bash

# Cleanup script for ToolHive demo-in-a-box Kubernetes cluster

# Source common helper functions
. "$(dirname "$0")/helpers.sh"

# Check if cluster exists
if ! kind get clusters 2>/dev/null | grep -q "^toolhive-demo-in-a-box$"; then
    echo "Kind cluster 'toolhive-demo-in-a-box' does not exist. Nothing to clean up."
    exit 0
fi

# Set KUBECONFIG for cleanup operations
export KUBECONFIG=$(pwd)/kubeconfig-toolhive-demo.yaml

# Explicitly delete ngrok Operator resources to avoid leaving orphaned resources in your ngrok account
echo -n "Cleaning up ngrok resources..."
run_quiet kubectl delete httproutes.gateway.networking.k8s.io --all --all-namespaces || true
run_quiet kubectl delete -f ngrok-gateway.yaml || true
run_quiet kubectl delete domains.ingress.k8s.ngrok.com --all --all-namespaces || true
run_quiet sh -c "kubectl get crd -o name | grep 'ngrok' | xargs -r kubectl delete" || true
run_quiet helm uninstall ngrok-operator --namespace ngrok-operator || true
echo " ✓"

# The rest we can just nuke from orbit. It's the only way to be sure.
echo -n "Deleting Kind cluster..."
run_quiet kind delete cluster --name toolhive-demo-in-a-box || true
rm -f kubeconfig-toolhive-demo.yaml
echo " ✓"

echo "Cleanup complete!"
