#!/bin/bash
. "$(dirname "$0")/../_lib.sh"

addon_load_env
addon_require_env OPENROUTER_API_KEY
addon_resolve_traefik

export LIBRECHAT_HOSTNAME="chat-${TRAEFIK_HOSTNAME_BASE}"

addon_create_namespace

# Generate secrets
echo -n "Creating secrets..."
CREDS_KEY=$(openssl rand -hex 32)
CREDS_IV=$(openssl rand -hex 16)
JWT_SECRET=$(openssl rand -hex 32)
JWT_REFRESH_SECRET=$(openssl rand -hex 32)
kubectl create secret generic librechat-credentials \
    --from-literal=OPENROUTER_API_KEY="$OPENROUTER_API_KEY" \
    --from-literal=CREDS_KEY="$CREDS_KEY" \
    --from-literal=CREDS_IV="$CREDS_IV" \
    --from-literal=JWT_SECRET="$JWT_SECRET" \
    --from-literal=JWT_REFRESH_SECRET="$JWT_REFRESH_SECRET" \
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
run_quiet helm upgrade --install librechat \
    oci://ghcr.io/danny-avila/librechat-chart/librechat \
    --namespace librechat \
    --values "$ADDON_DIR/values.yaml" \
    --set "librechat.configEnv.DOMAIN_CLIENT=$LIBRECHAT_URL" \
    --set "librechat.configEnv.DOMAIN_SERVER=$LIBRECHAT_URL" \
    --wait --timeout 5m
echo " done"

echo -n "Applying HTTPRoute..."
run_quiet addon_apply "$ADDON_DIR/httproute.yaml"
echo " done"

# Seed demo user via MongoDB (idempotent)
DEMO_EMAIL="demo@toolhive.local"
DEMO_PASS="demo1234"
echo -n "Seeding demo user..."
DEMO_HASH=$(kubectl exec -n librechat deployment/librechat -- \
    node -e "console.log(require('bcryptjs').hashSync('$DEMO_PASS', 10))" 2>/dev/null)
kubectl exec -n librechat librechat-mongodb-0 -- mongosh --quiet LibreChat --eval "
  if (db.users.countDocuments({ email: '$DEMO_EMAIL' }) === 0) {
    db.users.insertOne({
      name: 'Demo User',
      username: 'demo',
      email: '$DEMO_EMAIL',
      emailVerified: true,
      password: '$DEMO_HASH',
      role: 'ADMIN',
      createdAt: new Date(),
      updatedAt: new Date()
    });
    print('created');
  } else {
    print('exists');
  }
" > /dev/null
echo " done"

echo ""
echo "LibreChat is ready!"
echo "  URL: https://$LIBRECHAT_HOSTNAME (self-signed cert, expect a browser warning)"
echo "  Login: $DEMO_EMAIL / $DEMO_PASS"
echo "  vMCP gateways: vmcp-infra + vmcp-docs (in-cluster)"
