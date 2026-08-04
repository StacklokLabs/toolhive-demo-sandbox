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

# Copy the Traefik CA out of the traefik namespace. LibreChat's Node runtime
# needs it to validate the Keycloak issuer's TLS cert, and vmcp-chat's
# MCPOIDCConfig caBundleRef needs it in mcp-workloads to fetch OIDC discovery
# (bootstrap.sh only creates this ConfigMap in the platform namespace).
echo -n "Mirroring Traefik CA..."
CA_CRT=$(kubectl get secret sslip-io-tls -n traefik -o jsonpath='{.data.ca\.crt}' | base64 -d)
for ns in librechat mcp-workloads; do
    printf '%s' "$CA_CRT" \
        | kubectl create configmap traefik-ca -n "$ns" \
            --from-file=ca.crt=/dev/stdin \
            --dry-run=client -o yaml \
        | kubectl apply -f - > /dev/null
done
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
# Cedar authz ConfigMap must exist before the VirtualMCPServer references it.
echo -n "Applying vmcp-chat authz policies..."
run_quiet addon_apply "$ADDON_DIR/vmcp-chat-authz.yaml"
echo " done"

echo -n "Applying vmcp-chat VirtualMCPServer..."
run_quiet addon_apply "$ADDON_DIR/vmcp-chat.yaml"
run_quiet kubectl wait --for=jsonpath='{.status.phase}'=Ready --timeout=5m \
    vmcp/vmcp-chat -n mcp-workloads
echo " done"

# Pre-seed the "Infra Agent" so a fresh install doesn't land on an empty agent
# list. LibreChat agents are per-author database objects with no declarative
# config, so they can only be created through the API — and with Keycloak-only
# auth there is no local account to create one under (personas are provisioned
# on first OIDC login, which hasn't happened yet at deploy time). So: insert a
# login-less ADMIN service account, mint a JWT for it with the instance's
# JWT_SECRET (exactly what LibreChat's own jwtStrategy validates), create the
# agent, and share it publicly so every persona sees it.
SEED_EMAIL="librechat-seed@toolhive.local"
echo -n "Creating agent seed service account..."
SEED_USER_ID=$(kubectl exec -n librechat librechat-mongodb-0 -- \
    mongosh --quiet LibreChat --eval "
      const existing = db.users.findOne({ email: '$SEED_EMAIL' });
      if (existing) {
        print(existing._id.toString());
      } else {
        // No password field — this account exists only to own seeded objects
        // and cannot be logged into (ALLOW_EMAIL_LOGIN is false regardless).
        print(db.users.insertOne({
          name: 'ToolHive Seeder',
          username: 'toolhive-seed',
          email: '$SEED_EMAIL',
          emailVerified: true,
          role: 'ADMIN',
          createdAt: new Date(),
          updatedAt: new Date()
        }).insertedId.toString());
      }
    " | tr -d '\r')
[ -n "$SEED_USER_ID" ] || die "Failed to create the LibreChat seed service account"
echo " done"

# Runs inside the LibreChat pod: it already has node, jsonwebtoken, and
# JWT_SECRET in its environment, which avoids both a curl sidecar (the image
# ships no curl) and passing the signing secret around.
echo -n "Seeding Infra Agent..."
kubectl exec -i -n librechat deployment/librechat -- \
    env "SEED_USER_ID=$SEED_USER_ID" node -e '
      const jwt = require("jsonwebtoken");
      const payload = JSON.parse(require("fs").readFileSync(0, "utf8"));
      const token = jwt.sign({ id: process.env.SEED_USER_ID }, process.env.JWT_SECRET, {
        expiresIn: "5m",
      });
      const headers = {
        "Content-Type": "application/json",
        Authorization: `Bearer ${token}`,
        // LibreChat pipes these routes through uaParser, which rejects
        // non-browser user agents.
        "User-Agent":
          "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120 Safari/537.36",
      };
      const call = async (method, path, body) => {
        const res = await fetch(`http://localhost:3080${path}`, {
          method,
          headers,
          body: body ? JSON.stringify(body) : undefined,
        });
        const text = await res.text();
        if (!res.ok) {
          throw new Error(`${method} ${path} -> ${res.status} ${text}`);
        }
        return text ? JSON.parse(text) : null;
      };
      (async () => {
        const list = await call("GET", "/api/agents");
        const existing = (list?.data ?? []).find((a) => a.name === payload.name);
        const agent = existing ?? (await call("POST", "/api/agents", payload));
        // Agents are author-scoped: without a public grant only the seed
        // account would see it, and nobody ever logs in as that account.
        // agent_editor (VIEW|EDIT) rather than agent_viewer (VIEW) so the
        // personas can open the agent in the builder and inspect or tweak
        // its config live, which is the point of the demo. Granting to one
        // persona instead is not possible here: personas do not exist in
        // LibreChat until their first OIDC login, well after deploy.
        await call("PUT", `/api/permissions/agent/${agent._id}`, {
          public: true,
          publicAccessRoleId: "agent_editor",
        });
      })().catch((err) => {
        console.error(err.message);
        process.exit(1);
      });
    ' < "$ADDON_DIR/infra-agent.json" > /dev/null \
    || die "Failed to seed the Infra Agent"
echo " done"

echo ""
echo "LibreChat is ready!"
echo "  URL:    https://$LIBRECHAT_HOSTNAME (self-signed cert, expect a browser warning)"
echo "  Login:  via Keycloak (https://$AUTH_HOSTNAME) — any realm user works"
echo "          demo / demo    (all groups)"
echo "          alice / alice  (engineering)"
echo "          bob / bob      (finance)"
echo "  vMCP gateways: vmcp-chat (authenticated, in-cluster) + vmcp-docs"
