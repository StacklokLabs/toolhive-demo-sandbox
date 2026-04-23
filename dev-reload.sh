#!/bin/bash
set -e

# Build local ToolHive images, load them into the kind cluster, and restart
# affected pods so the demo picks up your changes.
#
# Usage:
#   ./dev-reload.sh [--operator] [--proxyrunner] [--vmcp] [--all]
#   TOOLHIVE_SRC=~/path/to/toolhive ./dev-reload.sh
#
# Flags (default: --all):
#   --operator      Build and reload the operator image
#   --proxyrunner   Build and reload the proxyrunner image (MCPServer / MCPRemoteProxy pods)
#   --vmcp          Build and reload the vMCP image (VirtualMCPServer pods)
#   --all           Build and reload all three (default)
#
# Requires:
#   - TOOLHIVE_SRC env var pointing to the toolhive repo checkout
#     (defaults to ../toolhive relative to this script)
#   - ko (https://ko.build)
#   - task (https://taskfile.dev)
#   - kind, kubectl, docker

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
. "$SCRIPT_DIR/helpers.sh"

TOOLHIVE_SRC="${TOOLHIVE_SRC:-$(cd "$SCRIPT_DIR/../../stacklok/toolhive" 2>/dev/null && pwd)}"
if [ -z "$TOOLHIVE_SRC" ] || [ ! -d "$TOOLHIVE_SRC" ]; then
    TOOLHIVE_SRC="$(cd "$SCRIPT_DIR/../toolhive" 2>/dev/null && pwd)"
fi
KIND_CLUSTER="toolhive-demo-in-a-box"
KUBECONFIG_FILE="$SCRIPT_DIR/kubeconfig-toolhive-demo.yaml"

if [ -z "$TOOLHIVE_SRC" ] || [ ! -d "$TOOLHIVE_SRC" ]; then
    die "ToolHive source not found — set TOOLHIVE_SRC to the repo path"
fi
if [ ! -f "$KUBECONFIG_FILE" ]; then
    die "Kubeconfig not found at $KUBECONFIG_FILE — run bootstrap.sh first"
fi

export KUBECONFIG="$KUBECONFIG_FILE"

# Discover the image tags currently in use on the cluster. We retag the locally
# built images to match these so imagePullPolicy=IfNotPresent uses the new image
# from the node cache without any deployment patching.
OPERATOR_IMAGE=$(kubectl get deployment toolhive-operator -n toolhive-system \
    -o jsonpath='{.spec.template.spec.containers[?(@.name=="manager")].image}' 2>/dev/null || echo "")

# proxyrunner and vmcp image refs live in the operator's ConfigMap/env, but the
# simplest source of truth is an existing pod that already uses them.
PROXYRUNNER_IMAGE=$(kubectl get deployment -n toolhive-system -o json 2>/dev/null \
    | python3 -c "
import json, sys
data = json.load(sys.stdin)
for d in data['items']:
    for c in d['spec']['template']['spec']['containers']:
        if 'toolhive/proxyrunner' in c.get('image', ''):
            print(c['image'])
            sys.exit()
" || echo "")

VMCP_IMAGE=$(kubectl get deployment -n toolhive-system -o json 2>/dev/null \
    | python3 -c "
import json, sys
data = json.load(sys.stdin)
for d in data['items']:
    for c in d['spec']['template']['spec']['containers']:
        if 'toolhive/vmcp' in c.get('image', ''):
            print(c['image'])
            sys.exit()
" || echo "")

# Parse flags
BUILD_OPERATOR=false
BUILD_PROXYRUNNER=false
BUILD_VMCP=false

if [ $# -eq 0 ]; then
    BUILD_OPERATOR=true
    BUILD_PROXYRUNNER=true
    BUILD_VMCP=true
fi

for arg in "$@"; do
    case "$arg" in
        --operator)    BUILD_OPERATOR=true ;;
        --proxyrunner) BUILD_PROXYRUNNER=true ;;
        --vmcp)        BUILD_VMCP=true ;;
        --all)         BUILD_OPERATOR=true; BUILD_PROXYRUNNER=true; BUILD_VMCP=true ;;
        *)             die "Unknown flag: $arg" ;;
    esac
done

# Build a ko image for the given cmd path, find it in docker, retag it to match
# the cluster's expected image ref, load into kind, and print the new image ref.
#   $1: short name for logging (e.g. "operator")
#   $2: ko image substring to grep for (e.g. "thv-operator")
#   $3: full target image ref from the cluster (e.g. "ghcr.io/.../operator:v0.23.1")
build_and_load() {
    local name="$1"
    local grep_key="$2"
    local target_image="$3"

    if [ -z "$target_image" ]; then
        echo "Skipping $name — no existing deployment found on the cluster"
        return
    fi

    echo -n "Building $name image..."
    case "$name" in
        operator)    run_quiet sh -c "cd '$TOOLHIVE_SRC' && task build-operator-image" ;;
        proxyrunner) run_quiet sh -c "cd '$TOOLHIVE_SRC' && KO_DOCKER_REPO=ghcr.io/stacklok/toolhive/proxyrunner ko build --local --bare ./cmd/thv-proxyrunner" ;;
        vmcp)        run_quiet sh -c "cd '$TOOLHIVE_SRC' && task build-vmcp-image" ;;
    esac
    echo " ✓"

    local ko_image
    ko_image=$(docker images --format '{{.Repository}}:{{.Tag}}' | grep "$grep_key" | grep -v "<none>" | head -1)
    if [ -z "$ko_image" ]; then
        die "Could not find built $name image (grep key: $grep_key)"
    fi

    echo -n "Tagging and loading $name ($target_image)..."
    run_quiet docker tag "$ko_image" "$target_image"
    run_quiet kind load docker-image "$target_image" --name "$KIND_CLUSTER"
    echo " ✓"
}

if $BUILD_OPERATOR; then
    build_and_load operator thv-operator "$OPERATOR_IMAGE"
    if [ -n "$OPERATOR_IMAGE" ]; then
        echo -n "Restarting operator..."
        run_quiet kubectl rollout restart deployment toolhive-operator -n toolhive-system
        run_quiet kubectl rollout status deployment toolhive-operator -n toolhive-system --timeout=120s
        echo " ✓"
    fi
fi

if $BUILD_PROXYRUNNER; then
    build_and_load proxyrunner thv-proxyrunner "$PROXYRUNNER_IMAGE"
    if [ -n "$PROXYRUNNER_IMAGE" ]; then
        echo -n "Restarting proxyrunner pods..."
        # Every deployment whose container image is the proxyrunner ref needs a roll.
        for d in $(kubectl get deployment -n toolhive-system -o json \
            | python3 -c "
import json, sys
data = json.load(sys.stdin)
for d in data['items']:
    for c in d['spec']['template']['spec']['containers']:
        if 'toolhive/proxyrunner' in c.get('image', ''):
            print(d['metadata']['name'])
            break
"); do
            run_quiet kubectl rollout restart deployment "$d" -n toolhive-system
        done
        echo " ✓"
    fi
fi

if $BUILD_VMCP; then
    build_and_load vmcp toolhive/vmcp "$VMCP_IMAGE"
    if [ -n "$VMCP_IMAGE" ]; then
        echo -n "Restarting vMCP pods..."
        for d in $(kubectl get deployment -n toolhive-system -o json \
            | python3 -c "
import json, sys
data = json.load(sys.stdin)
for d in data['items']:
    for c in d['spec']['template']['spec']['containers']:
        if 'toolhive/vmcp' in c.get('image', ''):
            print(d['metadata']['name'])
            break
"); do
            run_quiet kubectl rollout restart deployment "$d" -n toolhive-system
        done
        echo " ✓"
    fi
fi

echo "Done! Local builds loaded into $KIND_CLUSTER."
