#!/bin/bash
. "$(dirname "$0")/../_lib.sh"

addon_load_env
addon_require_env OPENROUTER_API_KEY
addon_resolve_traefik

export LIBRECHAT_HOSTNAME="chat-${TRAEFIK_HOSTNAME_BASE}"
# Exported for envsubst when applying vmcp-chat.yaml.
export AUTH_HOSTNAME="auth-${TRAEFIK_HOSTNAME_BASE}"
# Must match the secret configured for the "librechat" client in
# infra/keycloak.yaml. Keep them in sync.
KEYCLOAK_CLIENT_SECRET="librechat-secret-change-in-production"

addon_create_namespace

# Copy the Traefik CA from the traefik namespace so the LibreChat pod's Node
# runtime can validate the Keycloak issuer's TLS cert.
echo -n "Mirroring Traefik CA into librechat namespace..."
kubectl get secret traefik-me-tls -n traefik -o jsonpath='{.data.ca\.crt}' \
    | base64 -d \
    | kubectl create configmap traefik-ca -n librechat \
        --from-file=ca.crt=/dev/stdin \
        --dry-run=client -o yaml \
    | kubectl apply -f - > /dev/null
echo " done"

# Generate secrets
echo -n "Creating secrets..."
CREDS_KEY=$(openssl rand -hex 32)
CREDS_IV=$(openssl rand -hex 16)
JWT_SECRET=$(openssl rand -hex 32)
JWT_REFRESH_SECRET=$(openssl rand -hex 32)
OPENID_SESSION_SECRET=$(openssl rand -hex 32)
kubectl create secret generic librechat-credentials \
    --from-literal=OPENROUTER_API_KEY="$OPENROUTER_API_KEY" \
    --from-literal=CREDS_KEY="$CREDS_KEY" \
    --from-literal=CREDS_IV="$CREDS_IV" \
    --from-literal=JWT_SECRET="$JWT_SECRET" \
    --from-literal=JWT_REFRESH_SECRET="$JWT_REFRESH_SECRET" \
    --from-literal=OPENID_CLIENT_SECRET="$KEYCLOAK_CLIENT_SECRET" \
    --from-literal=OPENID_SESSION_SECRET="$OPENID_SESSION_SECRET" \
    --from-literal=MONGO_URI="mongodb://librechat-mongodb.librechat.svc.cluster.local:27017/LibreChat" \
    --namespace librechat \
    --dry-run=client -o yaml | kubectl apply -f - > /dev/null
echo " done"

# Deploy MongoDB (standalone — Bitnami subchart images are unreliable)
echo -n "Deploying MongoDB..."
run_quiet kubectl apply -f "$ADDON_DIR/mongodb.yaml"
run_quiet addon_wait_ready app=librechat-mongodb librechat 120s
echo " done"

echo -n "Installing LibreChat (Helm)..."
LIBRECHAT_URL="https://$LIBRECHAT_HOSTNAME"
OPENID_ISSUER="https://$AUTH_HOSTNAME/realms/toolhive-demo"
run_quiet helm upgrade --install librechat \
    oci://ghcr.io/danny-avila/librechat-chart/librechat \
    --namespace librechat \
    --values "$ADDON_DIR/values.yaml" \
    --set "librechat.configEnv.DOMAIN_CLIENT=$LIBRECHAT_URL" \
    --set "librechat.configEnv.DOMAIN_SERVER=$LIBRECHAT_URL" \
    --set "librechat.configEnv.OPENID_ISSUER=$OPENID_ISSUER" \
    --wait --timeout 5m
echo " done"

echo -n "Applying HTTPRoute..."
run_quiet addon_apply "$ADDON_DIR/httproute.yaml"
echo " done"

# Authenticated in-cluster vMCP for LibreChat. Accepts Keycloak user tokens
# bearing the toolhive-vmcp-chat audience; LibreChat forwards them via the
# {{LIBRECHAT_OPENID_ACCESS_TOKEN}} placeholder configured in values.yaml.
echo -n "Applying vmcp-chat VirtualMCPServer..."
run_quiet addon_apply "$ADDON_DIR/vmcp-chat.yaml"
run_quiet kubectl wait --for=jsonpath='{.status.phase}'=Ready --timeout=5m \
    vmcp/vmcp-chat -n toolhive-system
echo " done"

echo ""
echo "LibreChat is ready!"
echo "  URL:    https://$LIBRECHAT_HOSTNAME (self-signed cert, expect a browser warning)"
echo "  Login:  via Keycloak (https://$AUTH_HOSTNAME) — any realm user works"
echo "          demo / demo    (all groups)"
echo "          alice / alice  (engineering)"
echo "          bob / bob      (finance)"
echo "  vMCP gateways: vmcp-chat (authenticated, in-cluster) + vmcp-docs"
