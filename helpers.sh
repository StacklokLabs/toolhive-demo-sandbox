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
