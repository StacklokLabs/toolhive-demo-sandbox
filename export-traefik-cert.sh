#!/bin/bash
set -euo pipefail

# Exports the Traefik CA cert from the sslip-io-tls secret to a local file.
# Useful when an external tool (browser, curl, container) needs to trust the
# self-signed sslip.io endpoints fronted by Traefik.

OUTPUT_FILE="${1:-traefik-ca.crt}"
SECRET_NAME="sslip-io-tls"
SECRET_NAMESPACE="traefik"

if ! kubectl get secret "$SECRET_NAME" -n "$SECRET_NAMESPACE" >/dev/null 2>&1; then
    echo "Secret $SECRET_NAMESPACE/$SECRET_NAME not found. Is the demo cluster up?" >&2
    exit 1
fi

kubectl get secret "$SECRET_NAME" -n "$SECRET_NAMESPACE" \
    -o jsonpath='{.data.ca\.crt}' | base64 -d > "$OUTPUT_FILE"

if [[ ! -s "$OUTPUT_FILE" ]]; then
    echo "Wrote empty file; ca.crt was missing from $SECRET_NAMESPACE/$SECRET_NAME." >&2
    rm -f "$OUTPUT_FILE"
    exit 1
fi

echo "Wrote Traefik CA cert to $OUTPUT_FILE"
