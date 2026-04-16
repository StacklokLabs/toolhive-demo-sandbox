#!/bin/bash
. "$(dirname "$0")/../_lib.sh"

addon_load_env
addon_require_env OPENROUTER_API_KEY
addon_resolve_traefik

export LIBRECHAT_HOSTNAME="chat-${TRAEFIK_HOSTNAME_BASE}"

addon_create_namespace

# Generate LibreChat credential encryption keys
CREDS_KEY=$(openssl rand -hex 32)
CREDS_IV=$(openssl rand -hex 16)
JWT_SECRET=$(openssl rand -hex 32)
JWT_REFRESH_SECRET=$(openssl rand -hex 32)

echo -n "Creating secrets..."
kubectl create secret generic librechat-api-keys \
    --from-literal=openrouter-api-key="$OPENROUTER_API_KEY" \
    --from-literal=creds-key="$CREDS_KEY" \
    --from-literal=creds-iv="$CREDS_IV" \
    --from-literal=jwt-secret="$JWT_SECRET" \
    --from-literal=jwt-refresh-secret="$JWT_REFRESH_SECRET" \
    --namespace librechat \
    --dry-run=client -o yaml | kubectl apply -f - > /dev/null
echo " done"

echo -n "Deploying MongoDB..."
run_quiet kubectl apply -f "$ADDON_DIR/mongodb.yaml"
echo " done"

echo -n "Deploying LibreChat..."
run_quiet kubectl apply -f "$ADDON_DIR/librechat.yaml"
run_quiet addon_apply "$ADDON_DIR/librechat-app.yaml"
run_quiet kubectl rollout restart deployment/librechat -n librechat 2>/dev/null || true
echo " done"

echo -n "Waiting for MongoDB..."
run_quiet addon_wait_ready app=librechat-mongodb librechat 120s
echo " done"

echo -n "Waiting for LibreChat..."
run_quiet addon_wait_ready app=librechat librechat 180s
echo " done"

# Seed demo user via MongoDB (idempotent)
DEMO_EMAIL="demo@toolhive.local"
DEMO_PASS="demo1234"
echo -n "Seeding demo user..."
DEMO_HASH=$(kubectl exec -n librechat deployment/librechat -- \
    node -e "console.log(require('bcryptjs').hashSync('$DEMO_PASS', 10))" 2>/dev/null)
kubectl exec -n librechat librechat-mongodb-0 -- mongosh --quiet librechat --eval "
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
echo "  URL: http://$LIBRECHAT_HOSTNAME"
echo "  Login: $DEMO_EMAIL / $DEMO_PASS"
echo "  vMCP gateway: vmcp-demo (in-cluster)"
