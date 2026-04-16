#!/bin/bash
# Shared library for demo sandbox add-ons.
# Source this from your addon's deploy.sh or teardown.sh:
#   . "$(dirname "$0")/../_lib.sh"

set -e

# Resolve paths
ADDON_DIR="$(cd "$(dirname "${BASH_SOURCE[1]}")" && pwd)"
ADDON_NAME="$(basename "$ADDON_DIR")"
ADDONS_ROOT="$(cd "$ADDON_DIR/.." && pwd)"
REPO_ROOT="$(cd "$ADDONS_ROOT/.." && pwd)"

# Source repo helpers (run_quiet, die, wait_for_pods_ready, etc.)
. "$REPO_ROOT/helpers.sh"

# Use the demo kubeconfig if it exists
if [ -f "$REPO_ROOT/kubeconfig-toolhive-demo.yaml" ]; then
    export KUBECONFIG="$REPO_ROOT/kubeconfig-toolhive-demo.yaml"
fi

# Load .env — addon-local first, then repo root fallback
addon_load_env() {
    if [ -f "$ADDON_DIR/.env" ]; then
        set -a
        source "$ADDON_DIR/.env"
        set +a
    elif [ -f "$REPO_ROOT/.env" ]; then
        set -a
        source "$REPO_ROOT/.env"
        set +a
    fi
}

# Require an environment variable to be set, or die with a helpful message
addon_require_env() {
    local var_name="$1"
    if [ -z "${!var_name}" ]; then
        die "$var_name is not set. Add it to $ADDON_DIR/.env or export it."
    fi
}

# Resolve Traefik gateway IP and set hostname variables
addon_resolve_traefik() {
    echo -n "Resolving Traefik gateway IP..."
    TRAEFIK_IP=$(kubectl get gateways --namespace traefik traefik-gateway \
        -o "jsonpath={.status.addresses[0].value}" 2>/dev/null || echo "")
    if [ -z "$TRAEFIK_IP" ]; then
        die "Could not resolve Traefik Gateway IP. Is the demo cluster running?"
    fi
    TRAEFIK_HOSTNAME_BASE="${TRAEFIK_IP//./-}.traefik.me"
    echo " $TRAEFIK_IP"
}

# Create a namespace (idempotent)
addon_create_namespace() {
    local ns="${1:-$ADDON_NAME}"
    echo -n "Creating namespace $ns..."
    kubectl create namespace "$ns" --dry-run=client -o yaml | kubectl apply -f - > /dev/null
    echo " done"
}

# Delete a namespace
addon_delete_namespace() {
    local ns="${1:-$ADDON_NAME}"
    echo -n "Removing namespace $ns..."
    kubectl delete namespace "$ns" --ignore-not-found > /dev/null 2>&1
    echo " done"
}

# Apply a manifest file (supports envsubst)
addon_apply() {
    local file="$1"
    if grep -q '\$' "$file"; then
        envsubst < "$file" | kubectl apply -f - > /dev/null
    else
        kubectl apply -f "$file" > /dev/null
    fi
}

# Wait for all pods with a given label to be ready
addon_wait_ready() {
    local label="$1"
    local ns="${2:-$ADDON_NAME}"
    local timeout="${3:-180s}"
    kubectl wait --for=condition=ready pod -l "$label" -n "$ns" --timeout="$timeout"
}
