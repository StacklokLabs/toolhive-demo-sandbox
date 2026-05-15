#!/bin/sh
set -eu

read -r method target version || exit 0
while IFS= read -r header; do
    case "$header" in
        ""|$(printf '\r')) break ;;
    esac
done

path="${target%%\?*}"
api_server="https://${KUBERNETES_SERVICE_HOST}:${KUBERNETES_SERVICE_PORT}"
token_file="/var/run/secrets/kubernetes.io/serviceaccount/token"
ca_file="/var/run/secrets/kubernetes.io/serviceaccount/ca.crt"

kube_get() {
    path="$1"
    token="$(cat "$token_file")"
    SSL_CERT_FILE="$ca_file" wget -q -T 8 -O - \
        --header "Authorization: Bearer $token" \
        "$api_server$path" 2>/dev/null || printf '{"items":[]}'
}

json_header() {
    status="$1"
    printf 'HTTP/1.1 %s\r\n' "$status"
    printf 'Content-Type: application/json\r\n'
    printf 'Cache-Control: no-store\r\n'
    printf 'Connection: close\r\n'
    printf '\r\n'
}

resource() {
    kind="$1"
    api_path="$2"
    if [ "${first:-}" = "false" ]; then
        printf ','
    fi
    first=false
    printf '"%s":' "$kind"
    kube_get "$api_path"
}

case "$path" in
    /estate-api|/estate-api/)
        json_header "200 OK"
        printf '{"resources":{'
        first=true
        resource "MCPServer" "/apis/toolhive.stacklok.dev/v1beta1/mcpservers"
        resource "MCPRemoteProxy" "/apis/toolhive.stacklok.dev/v1beta1/mcpremoteproxies"
        resource "MCPServerEntry" "/apis/toolhive.stacklok.dev/v1beta1/mcpserverentries"
        resource "VirtualMCPServer" "/apis/toolhive.stacklok.dev/v1beta1/virtualmcpservers"
        resource "MCPGroup" "/apis/toolhive.stacklok.dev/v1beta1/mcpgroups"
        resource "MCPOIDCConfig" "/apis/toolhive.stacklok.dev/v1beta1/mcpoidcconfigs"
        resource "MCPExternalAuthConfig" "/apis/toolhive.stacklok.dev/v1beta1/mcpexternalauthconfigs"
        resource "MCPRegistry" "/apis/toolhive.stacklok.dev/v1beta1/mcpregistries"
        resource "MCPTelemetryConfig" "/apis/toolhive.stacklok.dev/v1beta1/mcptelemetryconfigs"
        resource "EmbeddingServer" "/apis/toolhive.stacklok.dev/v1beta1/embeddingservers"
        resource "VirtualMCPCompositeToolDefinition" "/apis/toolhive.stacklok.dev/v1beta1/virtualmcpcompositetooldefinitions"
        resource "HTTPRoute" "/apis/gateway.networking.k8s.io/v1/httproutes"
        printf '},"keycloakConfigMap":'
        kube_get "/api/v1/namespaces/keycloak/configmaps/keycloak-realm-import"
        printf ',"warnings":[]}'
        ;;
    /estate-api/healthz)
        json_header "200 OK"
        printf '{"status":"ok"}'
        ;;
    *)
        json_header "404 Not Found"
        printf '{"error":"not found"}'
        ;;
esac
