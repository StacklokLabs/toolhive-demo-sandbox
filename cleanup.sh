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

# The rest we can just nuke from orbit. It's the only way to be sure.
echo -n "Deleting Kind cluster..."
run_quiet kind delete cluster --name toolhive-demo-in-a-box || true
rm -f kubeconfig-toolhive-demo.yaml
echo " ✓"

echo "Cleanup complete!"
