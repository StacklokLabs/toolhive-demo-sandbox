#!/bin/bash
. "$(dirname "$0")/../_lib.sh"

echo -n "Removing GitHub MCP server..."
kubectl delete -f "$ADDON_DIR/mcpserver.yaml" --ignore-not-found > /dev/null 2>&1 || true
echo " done"

echo -n "Removing GitHub token secret..."
kubectl delete secret github-local-token -n toolhive-system --ignore-not-found > /dev/null 2>&1
echo " done"

echo "GitHub MCP server removed."
