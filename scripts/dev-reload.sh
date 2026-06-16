#!/bin/bash
set -e

# Build local ToolHive images, load them into the kind cluster, and restart
# affected pods so the demo picks up your changes.
#
# Usage:
#   ./scripts/dev-reload.sh [--crds] [--operator] [--proxyrunner] [--vmcp] [--all]
#   TOOLHIVE_SRC=~/path/to/toolhive ./scripts/dev-reload.sh
#
# Flags (default: --all):
#   --crds          Helm-upgrade the operator CRDs from the local chart
#   --operator      Helm-upgrade the operator chart and reload the operator image
#   --proxyrunner   Build and reload the proxyrunner image (MCPServer / MCPRemoteProxy pods)
#   --vmcp          Build and reload the vMCP image (VirtualMCPServer pods)
#   --all           Update CRDs and reload all three images (default)
#
# Requires:
#   - TOOLHIVE_SRC env var pointing to the toolhive repo checkout
#     (defaults to ../toolhive relative to the repo root)
#   - ko (https://ko.build)
#   - task (https://taskfile.dev)
#   - kind >= 0.32.0, kubectl, docker
#     (kind 0.31 and earlier fail at `kind load` against kindest/node:v1.36.1
#      with "unknown containerd config version: 4" — fix: `brew upgrade kind`)

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
. "$SCRIPT_DIR/helpers.sh"
. "$REPO_ROOT/versions.env"   # CLUSTER_NAME

# Resolve TOOLHIVE_SRC. Try, in order: the env var (if set), then a couple
# of common checkout locations. The resolved path is printed below so it is
# obvious which clone we are building from — silently building from a
# stale path is the failure mode we are guarding against.
# The `|| true` guards keep `set -e` from killing the script when a candidate
# path is absent (a failed command substitution in a bare assignment is fatal
# under set -e); we want the explicit "not found" die below to run instead.
TOOLHIVE_SRC="${TOOLHIVE_SRC:-$(cd "$REPO_ROOT/../../stacklok/toolhive" 2>/dev/null && pwd || true)}"
if [ -z "$TOOLHIVE_SRC" ] || [ ! -d "$TOOLHIVE_SRC" ]; then
    TOOLHIVE_SRC="$(cd "$REPO_ROOT/../toolhive" 2>/dev/null && pwd || true)"
fi
KIND_CLUSTER="$CLUSTER_NAME"
KUBECONFIG_FILE="$REPO_ROOT/kubeconfig-toolhive-demo.yaml"

if [ -z "$TOOLHIVE_SRC" ] || [ ! -d "$TOOLHIVE_SRC" ]; then
    die "ToolHive source not found — set TOOLHIVE_SRC to the repo path"
fi
if [ ! -f "$KUBECONFIG_FILE" ]; then
    die "Kubeconfig not found at $KUBECONFIG_FILE — run bootstrap.sh first"
fi

export KUBECONFIG="$KUBECONFIG_FILE"

echo "Building from TOOLHIVE_SRC: $TOOLHIVE_SRC"

# Discover the image tags currently in use on the cluster. We retag the locally
# built images to match these so imagePullPolicy=IfNotPresent uses the new image
# from the node cache without any deployment patching.
OPERATOR_IMAGE=$(kubectl get deployment toolhive-operator -n toolhive-system \
    -o jsonpath='{.spec.template.spec.containers[?(@.name=="manager")].image}' 2>/dev/null || echo "")

# proxyrunner and vmcp image refs live in the operator's ConfigMap/env, but the
# simplest source of truth is an existing pod that already uses them. Workload
# pods (MCPServers / MCPRemoteProxies / VirtualMCPServers) live in mcp-workloads,
# not toolhive-system — the latter only holds the operator + registry + cloud-UI.
PROXYRUNNER_IMAGE=$(kubectl get deployment -n mcp-workloads -o json 2>/dev/null \
    | python3 -c "
import json, sys
data = json.load(sys.stdin)
for d in data['items']:
    for c in d['spec']['template']['spec']['containers']:
        if 'toolhive/proxyrunner' in c.get('image', ''):
            print(c['image'])
            sys.exit()
" || echo "")

VMCP_IMAGE=$(kubectl get deployment -n mcp-workloads -o json 2>/dev/null \
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
UPDATE_CRDS=false
BUILD_OPERATOR=false
BUILD_PROXYRUNNER=false
BUILD_VMCP=false

if [ $# -eq 0 ]; then
    UPDATE_CRDS=true
    BUILD_OPERATOR=true
    BUILD_PROXYRUNNER=true
    BUILD_VMCP=true
fi

for arg in "$@"; do
    case "$arg" in
        --crds)        UPDATE_CRDS=true ;;
        --operator)    BUILD_OPERATOR=true ;;
        --proxyrunner) BUILD_PROXYRUNNER=true ;;
        --vmcp)        BUILD_VMCP=true ;;
        --all)         UPDATE_CRDS=true; BUILD_OPERATOR=true; BUILD_PROXYRUNNER=true; BUILD_VMCP=true ;;
        *)             die "Unknown flag: $arg" ;;
    esac
done

# Build a ko image for the given cmd path, find the freshly-built :latest tag
# in docker, retag it to match the cluster's expected image ref, and load it
# into kind.
#
# Why ":latest" rather than searching by repo+sort? ko sets the image's
# Created timestamp deterministically from SOURCE_DATE_EPOCH (the git commit
# time), so all builds at the same HEAD report the same Created time and
# can't be ordered by it. ko DOES, however, retag :latest on every build,
# so :latest is the only reliable pointer to the freshest build.
#
#   $1: short name for logging (e.g. "operator")
#   $2: image repo that ko writes to. Must match the ACTUAL build output:
#         operator    → ko.local/thv-operator      (KO_DOCKER_REPO unset, -B)
#         proxyrunner → ghcr.io/stacklok/toolhive/proxyrunner (--bare)
#         vmcp        → ghcr.io/stacklok/toolhive/vmcp        (--bare)
#       NOTE: ko writes to ko.local (not kind.local) when KO_DOCKER_REPO
#       is unset. There may be stale `kind.local/...` images from an
#       earlier bootstrap pipeline; those are NOT what we want.
#   $3: full target image ref from the cluster (e.g. "ghcr.io/.../operator:v0.23.1")
build_and_load() {
    local name="$1"
    local image_repo="$2"
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

    # ko maintains ":latest" pointing at the most recent build for this repo.
    local ko_image="${image_repo}:latest"
    if ! docker image inspect "$ko_image" >/dev/null 2>&1; then
        die "Could not find built $name image at $ko_image (did ko build run successfully?)"
    fi

    # The image ID (content digest) changes on every source change, so a
    # stale-image regression shows up as the same digest across reload cycles.
    local image_id
    image_id=$(docker image inspect --format='{{.Id}}' "$ko_image" | cut -d':' -f2 | head -c 12)

    echo -n "Tagging and loading $name ($target_image, image id: $image_id)..."
    run_quiet docker tag "$ko_image" "$target_image"
    run_quiet kind load docker-image "$target_image" --name "$KIND_CLUSTER"
    echo " ✓"
}

if $UPDATE_CRDS; then
    CRDS_CHART="$TOOLHIVE_SRC/deploy/charts/operator-crds"
    if [ ! -d "$CRDS_CHART" ]; then
        die "CRD chart not found at $CRDS_CHART"
    fi
    echo -n "Upgrading ToolHive CRDs from $CRDS_CHART..."
    run_quiet helm upgrade --install toolhive-operator-crds "$CRDS_CHART" --namespace toolhive-system --create-namespace --wait
    echo " ✓"
fi

if $BUILD_OPERATOR; then
    OPERATOR_CHART="$TOOLHIVE_SRC/deploy/charts/operator"
    if [ ! -d "$OPERATOR_CHART" ]; then
        die "Operator chart not found at $OPERATOR_CHART"
    fi
    echo -n "Upgrading ToolHive operator chart from $OPERATOR_CHART..."
    # No --wait: if the chart bumps image.tag, the new pod can't pull until we
    # build_and_load below. The rollout status at the end provides the wait.
    run_quiet helm upgrade --install toolhive-operator "$OPERATOR_CHART" \
        --namespace toolhive-system --create-namespace
    echo " ✓"

    # Re-query the image ref — the chart upgrade may have changed it.
    OPERATOR_IMAGE=$(kubectl get deployment toolhive-operator -n toolhive-system \
        -o jsonpath='{.spec.template.spec.containers[?(@.name=="manager")].image}' 2>/dev/null || echo "")

    build_and_load operator ko.local/thv-operator "$OPERATOR_IMAGE"
    if [ -n "$OPERATOR_IMAGE" ]; then
        echo -n "Restarting operator..."
        run_quiet kubectl rollout restart deployment toolhive-operator -n toolhive-system
        run_quiet kubectl rollout status deployment toolhive-operator -n toolhive-system --timeout=120s
        echo " ✓"
    fi
fi

if $BUILD_PROXYRUNNER; then
    build_and_load proxyrunner ghcr.io/stacklok/toolhive/proxyrunner "$PROXYRUNNER_IMAGE"
    if [ -n "$PROXYRUNNER_IMAGE" ]; then
        echo -n "Restarting proxyrunner pods..."
        # Every deployment whose container image is the proxyrunner ref needs a roll.
        for d in $(kubectl get deployment -n mcp-workloads -o json \
            | python3 -c "
import json, sys
data = json.load(sys.stdin)
for d in data['items']:
    for c in d['spec']['template']['spec']['containers']:
        if 'toolhive/proxyrunner' in c.get('image', ''):
            print(d['metadata']['name'])
            break
"); do
            run_quiet kubectl rollout restart deployment "$d" -n mcp-workloads
        done
        echo " ✓"
    fi
fi

if $BUILD_VMCP; then
    build_and_load vmcp ghcr.io/stacklok/toolhive/vmcp "$VMCP_IMAGE"
    if [ -n "$VMCP_IMAGE" ]; then
        echo -n "Restarting vMCP pods..."
        for d in $(kubectl get deployment -n mcp-workloads -o json \
            | python3 -c "
import json, sys
data = json.load(sys.stdin)
for d in data['items']:
    for c in d['spec']['template']['spec']['containers']:
        if 'toolhive/vmcp' in c.get('image', ''):
            print(d['metadata']['name'])
            break
"); do
            run_quiet kubectl rollout restart deployment "$d" -n mcp-workloads
        done
        echo " ✓"
    fi
fi

echo "Done! Local builds loaded into $KIND_CLUSTER."
