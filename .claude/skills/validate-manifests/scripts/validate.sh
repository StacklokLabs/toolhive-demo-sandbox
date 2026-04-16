#!/usr/bin/env bash
# Server-side dry-run validation for ToolHive demo sandbox manifests.
# Requires a running kind cluster (KUBECONFIG=./kubeconfig-toolhive-demo.yaml).
#
# Usage:
#   validate.sh                 # validate all changed YAMLs since HEAD (+ untracked)
#   validate.sh --all           # validate every YAML under scoped dirs
#   validate.sh <file>...       # validate specific file(s)
set -u
set -o pipefail

SCOPE_DIRS=(demo-manifests addons infra)

# Find repo root
REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null)" || {
    echo "Error: not inside a git repository" >&2
    exit 1
}
cd "$REPO_ROOT"

# Point at the demo kubeconfig if it exists
if [ -f "$REPO_ROOT/kubeconfig-toolhive-demo.yaml" ]; then
    export KUBECONFIG="$REPO_ROOT/kubeconfig-toolhive-demo.yaml"
fi

# Confirm cluster reachability up front
if ! kubectl cluster-info >/dev/null 2>&1; then
    echo "Error: kubectl cluster-info failed. Is the kind cluster running?" >&2
    echo "       KUBECONFIG=$KUBECONFIG" >&2
    exit 1
fi

# Placeholder values for envsubst — safe strings that satisfy URL-ish
# patterns and CRD validation without pointing at anything real.
# Keep in sync with new $VARs introduced in manifests:
#   find demo-manifests addons infra \( -name '*.yaml' -o -name '*.yml' \) \
#     -exec grep -hoE '\$\{?[A-Z_][A-Z0-9_]*\}?' {} \; | sed 's/[${}]//g' | sort -u
export MCP_HOSTNAME="mcp.validate.local"
export REGISTRY_HOSTNAME="registry.validate.local"
export AUTH_HOSTNAME="auth.validate.local"
export UI_HOSTNAME="ui.validate.local"
export GRAFANA_HOSTNAME="grafana.validate.local"
export LIBRECHAT_HOSTNAME="chat.validate.local"
export KEYCLOAK_VERSION="0.0.0"
export CLOUD_UI_VERSION="v0.0.0"
export EMBEDDING_IMAGE="ghcr.io/huggingface/text-embeddings-inference:cpu-latest"
export OPENROUTER_API_KEY="placeholder-openrouter-key"
export VMCP_OKTA_CLOUDFLARED_DOMAIN="vmcp.validate.local"
export OKTA_ISSUER_URL="https://placeholder.okta.com/oauth2/placeholder"
export VMCP_OKTA_CLIENT_ID="placeholder-client-id"
export VMCP_OKTA_CLIENT_SECRET="placeholder-client-secret"
export VMCP_OKTA_CLOUDFLARED_TUNNEL_TOKEN="placeholder-tunnel-token"

# Collect files to validate.
files=()
if [ $# -eq 0 ]; then
    # Changed vs HEAD + staged + untracked, scoped to the target dirs.
    while IFS= read -r f; do
        [ -n "$f" ] || continue
        case "$f" in *.yaml|*.yml) files+=("$f") ;; esac
    done < <({
        git diff --name-only HEAD -- "${SCOPE_DIRS[@]}" 2>/dev/null
        git ls-files --others --exclude-standard -- "${SCOPE_DIRS[@]}" 2>/dev/null
    } | sort -u)
elif [ "$1" = "--all" ]; then
    while IFS= read -r f; do files+=("$f"); done < <(
        find "${SCOPE_DIRS[@]}" \( -name '*.yaml' -o -name '*.yml' \) -type f | sort
    )
else
    files=("$@")
fi

if [ ${#files[@]} -eq 0 ]; then
    echo "No manifests to validate."
    exit 0
fi

pass=0
fail=0
skipped=0
failures=()

for f in "${files[@]}"; do
    if [ ! -f "$f" ]; then
        printf "  SKIP  %s  (file not found — deleted?)\n" "$f"
        skipped=$((skipped+1))
        continue
    fi
    # Skip files that aren't full K8s manifests:
    # - helm values files (no apiVersion/kind)
    # - strategic-merge patch files (applied via kubectl patch, not apply)
    case "$f" in
        *helm-values.yaml|*helm-values.yml|*values.yaml)
            printf "  SKIP  %s  (helm values, not a k8s manifest)\n" "$f"
            skipped=$((skipped+1))
            continue ;;
        */patch.yaml|*-patch.yaml)
            printf "  SKIP  %s  (strategic-merge patch, not a full manifest)\n" "$f"
            skipped=$((skipped+1))
            continue ;;
    esac
    # Always run envsubst — idempotent for files without placeholders, and
    # both $VAR and ${VAR} forms need to be handled.
    rendered=$(envsubst < "$f")
    if err=$(printf '%s' "$rendered" | kubectl apply --dry-run=server -f - 2>&1 >/dev/null); then
        printf "  PASS  %s\n" "$f"
        pass=$((pass+1))
    else
        printf "  FAIL  %s\n" "$f"
        # kubectl often echoes the full applied config on one huge line before
        # the actual error. Pull out only the diagnostic substrings.
        summary=$(printf '%s' "$err" | python3 -c '
import re, sys
text = sys.stdin.read()
patterns = [
    r"strict decoding error: unknown field \"[^\"]+\"",
    r"Invalid value: \"[^\"]+\": [^\"}]+",
    r"The [A-Za-z]+ \"[^\"]+\" is invalid: [a-zA-Z0-9_.\[\]]+: Invalid value: \"[^\"]+\": [^\"}]+",
    r"error parsing [^:]+: [^\n]+",
    r"error converting YAML to JSON: [^\n]+",
    r"error validating data: [^\n]+",
]
hits = []
for p in patterns:
    for m in re.findall(p, text):
        s = m.strip().rstrip(",:")
        if s and s not in hits:
            hits.append(s)
for h in hits[:6]:
    print(h)
' 2>/dev/null)
        if [ -z "$summary" ]; then
            # Unknown shape — show a truncated tail
            summary=$(printf '%s' "$err" | tail -c 300)
        fi
        printf '%s\n' "$summary" | sed 's/^/        /'
        fail=$((fail+1))
        failures+=("$f")
    fi
done

echo
echo "Summary: $pass passed, $fail failed, $skipped skipped  ($((pass+fail+skipped)) total)"

if [ $fail -gt 0 ]; then
    exit 1
fi
