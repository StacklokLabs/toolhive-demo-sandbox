#!/bin/bash

# Common helper functions for ToolHive demo-in-a-box scripts

# Enable debug mode with DEBUG=1 environment variable
DEBUG=${DEBUG:-0}

# Helper function to run commands quietly unless DEBUG=1
run_quiet() {
    if [ "$DEBUG" = "1" ]; then
        "$@"
    else
        local tmpfile=$(mktemp)
        if "$@" > /dev/null 2> "$tmpfile"; then
            rm -f "$tmpfile"
            return 0
        else
            local exit_code=$?
            cat "$tmpfile" >&2
            rm -f "$tmpfile"
            return $exit_code
        fi
    fi
}

# Helper function to display error and exit
die() {
    echo "ERROR: $*" >&2
    exit 1
}

# Helper function to check if namespace exists
namespace_exists() {
    kubectl get namespace "$1" > /dev/null 2>&1
}

# Helper function to check if secret exists
secret_exists() {
    kubectl get secret "$1" --namespace "$2" > /dev/null 2>&1
}

# Wait for all pods in a namespace to be ready, tolerating pod churn from updates.
wait_for_pods_ready() {
    local namespace="$1"
    local timeout="${2:-300}"
    local deadline=$((SECONDS + timeout))

    while [ $SECONDS -lt $deadline ]; do
        # Get pods, filtering out Completed and Terminating which aren't relevant
        local pod_lines
        pod_lines=$(kubectl get pods -n "$namespace" --no-headers 2>/dev/null | grep -v -E "Completed|Terminating" || true)

        # If there are no active pods yet (all still terminating/completed), wait
        if [ -z "$pod_lines" ]; then
            sleep 2
            continue
        fi

        # Check the READY column (e.g. "1/1") — pod is ready when both numbers match
        local not_ready
        not_ready=$(echo "$pod_lines" | awk '{split($2, a, "/"); if (a[1] != a[2]) found++} END {print found+0}')

        if [ "$not_ready" -eq 0 ]; then
            return 0
        fi

        sleep 2
    done

    return 1
}
