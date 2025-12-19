#!/bin/bash

# Cleanup script for ToolHive demo-in-a-box Kubernetes cluster

# Source common helper functions
. "$(dirname "$0")/helpers.sh"

# Remove local Docker images used by the demo (do this first, regardless of cluster state)
echo -n "Removing demo Docker images..."
run_quiet docker rmi toolhive-mock-oidc-provider:demo-v1 2>/dev/null || true
echo " ✓"

# Check if cluster exists
if ! kind get clusters 2>/dev/null | grep -q "^toolhive-demo-in-a-box$"; then
    echo "Kind cluster 'toolhive-demo-in-a-box' does not exist. Nothing more to clean up."
    exit 0
fi

# Set KUBECONFIG for cleanup operations
export KUBECONFIG=$(pwd)/kubeconfig-toolhive-demo.yaml

# The rest we can just nuke from orbit. It's the only way to be sure.
echo -n "Deleting Kind cluster..."
run_quiet kind delete cluster --name toolhive-demo-in-a-box || true
rm -f kubeconfig-toolhive-demo.yaml
echo " ✓"

echo "Cleanup complete!"
