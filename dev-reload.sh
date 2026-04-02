#!/bin/bash
set -e

# Build local ToolHive images, load them into the kind cluster, and restart affected pods.
#
# Usage:
#   ./dev-reload.sh [--operator] [--vmcp] [--all]
#   TOOLHIVE_SRC=~/Documents/GitHub/toolhive ./dev-reload.sh
#
# Flags:
#   --operator   Build and reload the operator
#   --vmcp       Build and reload the vMCP server
#   --all        Build and reload both (default if no flags given)
#
# Requires:
#   - TOOLHIVE_SRC environment variable pointing to the toolhive repo
#     (defaults to ../toolhive relative to this script)
#   - ko (https://ko.build)
#   - task (https://taskfile.dev)
#   - kind, kubectl

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
. "$SCRIPT_DIR/helpers.sh"

TOOLHIVE_SRC="${TOOLHIVE_SRC:-$(cd "$SCRIPT_DIR/../toolhive" 2>/dev/null && pwd)}"
KIND_CLUSTER="toolhive-demo-in-a-box"
KUBECONFIG_FILE="$SCRIPT_DIR/kubeconfig-toolhive-demo.yaml"

if [ ! -d "$TOOLHIVE_SRC" ]; then
    die "ToolHive source not found at $TOOLHIVE_SRC — set TOOLHIVE_SRC to the repo path"
fi

if [ ! -f "$KUBECONFIG_FILE" ]; then
    die "Kubeconfig not found at $KUBECONFIG_FILE — run bootstrap.sh first"
fi

export KUBECONFIG="$KUBECONFIG_FILE"

# Determine the image tag the operator expects
OPERATOR_IMAGE=$(kubectl get deployment toolhive-operator -n toolhive-system -o jsonpath='{.spec.template.spec.containers[?(@.name=="manager")].image}')
VMCP_IMAGE=$(kubectl get deployment vmcp-google-drive -n toolhive-system -o jsonpath='{.spec.template.spec.containers[?(@.name=="vmcp")].image}' 2>/dev/null || echo "")

OPERATOR_TAG="${OPERATOR_IMAGE##*:}"
VMCP_TAG="${VMCP_IMAGE##*:}"

# Parse flags
BUILD_OPERATOR=false
BUILD_VMCP=false

if [ $# -eq 0 ]; then
    BUILD_OPERATOR=true
    BUILD_VMCP=true
fi

for arg in "$@"; do
    case "$arg" in
        --operator) BUILD_OPERATOR=true ;;
        --vmcp)     BUILD_VMCP=true ;;
        --all)      BUILD_OPERATOR=true; BUILD_VMCP=true ;;
        *)          die "Unknown flag: $arg" ;;
    esac
done

if $BUILD_OPERATOR; then
    echo -n "Building operator image..."
    (cd "$TOOLHIVE_SRC" && task build-operator-image) > /dev/null 2>&1 || die "Failed to build operator image"
    echo " ✓"

    # ko produces the image name from the module path; find what it built
    KO_IMAGE=$(docker images --format '{{.Repository}}:{{.Tag}}' | grep "thv-operator" | head -1)
    if [ -z "$KO_IMAGE" ]; then
        die "Could not find built operator image"
    fi

    echo -n "Tagging and loading operator image ($OPERATOR_TAG)..."
    run_quiet docker tag "$KO_IMAGE" "$OPERATOR_IMAGE" || die "Failed to tag operator image"
    run_quiet kind load docker-image "$OPERATOR_IMAGE" --name "$KIND_CLUSTER" || die "Failed to load operator image"
    echo " ✓"

    echo -n "Restarting operator..."
    run_quiet kubectl rollout restart deployment toolhive-operator -n toolhive-system || die "Failed to restart operator"
    run_quiet kubectl rollout status deployment toolhive-operator -n toolhive-system --timeout=120s || die "Operator failed to become ready"
    echo " ✓"
fi

if $BUILD_VMCP; then
    if [ -z "$VMCP_IMAGE" ]; then
        echo "Skipping vMCP — no vmcp-google-drive deployment found (deploy vmcp-demo-auth first)"
    else
        echo -n "Building vMCP image..."
        (cd "$TOOLHIVE_SRC" && KO_DOCKER_REPO=ghcr.io/stacklok/toolhive/vmcp task build-vmcp-image) > /dev/null 2>&1 || die "Failed to build vMCP image"
        echo " ✓"

        KO_IMAGE=$(docker images --format '{{.Repository}}:{{.Tag}}' | grep "toolhive/vmcp" | head -1)
        if [ -z "$KO_IMAGE" ]; then
            die "Could not find built vMCP image"
        fi

        echo -n "Tagging and loading vMCP image ($VMCP_TAG)..."
        run_quiet docker tag "$KO_IMAGE" "$VMCP_IMAGE" || die "Failed to tag vMCP image"
        run_quiet kind load docker-image "$VMCP_IMAGE" --name "$KIND_CLUSTER" || die "Failed to load vMCP image"
        echo " ✓"

        echo -n "Restarting vMCP pods..."
        run_quiet kubectl delete pods -n toolhive-system -l app.kubernetes.io/instance=vmcp-google-drive || die "Failed to restart vMCP pods"
        echo " ✓"
    fi
fi

echo "Done! Local builds loaded into $KIND_CLUSTER."
