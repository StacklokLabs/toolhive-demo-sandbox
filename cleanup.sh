#!/bin/bash

# Cleanup script for the ToolHive demo sandbox Kubernetes cluster.

# Source common helper functions and identity vars
. "$(dirname "$0")/scripts/helpers.sh"
. "$(dirname "$0")/versions.env"

# Names to look for: the current cluster name plus any legacy names that
# may still be around from earlier versions of this script.
CLUSTER_NAMES=("${CLUSTER_NAME}" "toolhive-demo-in-a-box")

EXISTING=$(kind get clusters 2>/dev/null || true)
TO_DELETE=()
for name in "${CLUSTER_NAMES[@]}"; do
    if echo "$EXISTING" | grep -q "^${name}$"; then
        TO_DELETE+=("$name")
    fi
done

if [ "${#TO_DELETE[@]}" -eq 0 ]; then
    echo "No matching Kind clusters found. Nothing more to clean up."
    exit 0
fi

# Set KUBECONFIG for cleanup operations
export KUBECONFIG=$(pwd)/${KUBECONFIG_FILE}

# The rest we can just nuke from orbit. It's the only way to be sure.
for name in "${TO_DELETE[@]}"; do
    echo -n "Deleting Kind cluster '${name}'..."
    run_quiet kind delete cluster --name "${name}" || true
    echo " ✓"
done

rm -f "${KUBECONFIG_FILE}" demo-endpoints.json

echo "Cleanup complete!"
