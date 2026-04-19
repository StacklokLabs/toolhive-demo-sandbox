# Troubleshooting

Common operational issues when running the demo sandbox. Structure:
**Symptom → Why → Fix**.

For bootstrap failures generally, re-run with `DEBUG=1 ./bootstrap.sh` for
verbose output, then `./validate.sh` to re-check endpoint health.

## Contents

- [Browser warning: "Your connection is not private"](#browser-warning-your-connection-is-not-private)
- [`kubectl get gateway` shows no IP address (`EXTERNAL-IP: <pending>`)](#kubectl-get-gateway-shows-no-ip-address-external-ip-pending)
- [OIDC login fails with "Invalid redirect URI"](#oidc-login-fails-with-invalid-redirect-uri)
- [Edits to `infra/keycloak.yaml` don't take effect on re-bootstrap](#edits-to-infrakeycloakyaml-dont-take-effect-on-re-bootstrap)
- [Registry server returns an empty list of servers](#registry-server-returns-an-empty-list-of-servers)
- [MCP resources stuck in `Pending` or `Failed`](#mcp-resources-stuck-in-pending-or-failed)
- [LibreChat: "Too many login attempts, please try again after 5 minutes"](#librechat-too-many-login-attempts-please-try-again-after-5-minutes)
- [Useful commands](#useful-commands)

---

### Browser warning: "Your connection is not private"

**Why.** Traefik fronts the sandbox with a self-signed wildcard cert for
`*.traefik.me`. That lets us have an HTTPS demo without a public DNS / CA
story, at the cost of a cert warning on first visit to each hostname.

**Fix.** Click through the warning once per hostname (auth, ui, chat,
registry, grafana). Your browser remembers the exception until it's
cleared. There's no need to install the CA — it's intended to be
untrusted outside the sandbox.

### `kubectl get gateway` shows no IP address (`EXTERNAL-IP: <pending>`)

**Why.** Services of type `LoadBalancer` on kind need
[`cloud-provider-kind`](https://github.com/kubernetes-sigs/cloud-provider-kind)
running on the host to allocate external IPs. It's a separate process
from the cluster itself — if it isn't running (crashed, laptop rebooted,
never started), `LoadBalancer` Services stay `<pending>` forever and
nothing with a hostname works.

**Fix.** Start the provider (leave it running in a dedicated terminal):

```sh
sudo cloud-provider-kind
```

Then re-check:

```sh
kubectl get gateway -n traefik traefik-gateway \
    -o jsonpath='{.status.addresses[0].value}'
```

### OIDC login fails with "Invalid redirect URI"

**Why.** Keycloak's realm is imported from `infra/keycloak.yaml` with
redirect URIs baked in for whatever Traefik LB IP was live at bootstrap
time (e.g. `172-19-0-3.traefik.me`). The realm persists on the
`keycloak-h2-data` PVC, so `--import-realm` is a no-op on subsequent
runs. If the Traefik IP drifts between bootstraps — typically because
`cloud-provider-kind` was restarted and handed out a different address
— every OIDC callback starts failing because the redirect URI in the
browser doesn't match what Keycloak has recorded.

**Fix.** `bootstrap.sh` detects drift automatically (it stamps the
current hostname base into a `keycloak-bootstrap-state` ConfigMap and
wipes the Keycloak PVC when the stamp doesn't match). A plain re-run
will heal it:

```sh
./bootstrap.sh
```

If you need to patch the live realm without re-bootstrapping (e.g.
you're mid-demo), see the admin-API snippet under
[Useful commands](#patch-keycloak-client-redirect-uris-in-place).

### Edits to `infra/keycloak.yaml` don't take effect on re-bootstrap

**Why.** Same root cause as the redirect-URI drift: `--import-realm` is
a no-op once the realm exists on the PVC. New client scopes, protocol
mappers, users, etc. added to the manifest will not appear in the
running realm just because you re-applied the manifest.

**Fix.** Wipe the Keycloak state so the next boot re-imports:

```sh
kubectl delete deployment keycloak -n keycloak
kubectl delete pvc keycloak-h2-data -n keycloak
kubectl delete configmap keycloak-bootstrap-state -n keycloak --ignore-not-found
./bootstrap.sh
```

Wiping the PVC destroys signing keys, so any clients holding refresh
tokens issued before the wipe will need to re-authenticate. Fine for a
demo.

### Registry server returns an empty list of servers

**Why.** The registry's K8s source picks up `MCPServer`,
`MCPRemoteProxy`, and `VirtualMCPServer` resources carrying
`toolhive.stacklok.dev/registry-export: "true"` only once they reach
`phase: Ready`. Two common causes of an empty response:

1. One or more MCP resources are stuck below `Ready` (see next entry).
2. The caller's token doesn't match any entry's `authz-claims`
   annotation. E.g. an `alice`-issued token won't see finance-gated
   servers.

**Fix.** Verify MCP readiness first:

```sh
kubectl get mcpserver,mcpremoteproxy,vmcp -A
```

If everything's `Ready`, double-check the persona you're querying as:

```sh
# As demo (member of all groups) — should return every exported entry
TOKEN=$(...)  # see "mint a user token" under Useful commands
curl -s "http://$REG/registry/demo-registry/v0.1/servers?limit=200" \
    -H "Authorization: Bearer $TOKEN" \
    | python3 -c "import sys,json; print(len(json.load(sys.stdin)['servers']))"
```

### MCP resources stuck in `Pending` or `Failed`

**Why.** Usually one of:

- The backing pod is in `ImagePullBackOff` — often a rate limit on
  `ghcr.io` / `docker.io` or a network outage. Docker Desktop running
  low on disk also triggers this.
- The operator hasn't reconciled yet (transient, resolves in a minute).
- A schema mismatch if the manifest predates the currently-installed
  operator version — run the validator before re-applying:

```sh
.claude/skills/validate-manifests/scripts/validate.sh
```

**Fix.** Find the problem resource and look at its events:

```sh
kubectl get mcpserver,mcpremoteproxy,vmcp -A | grep -vE "Ready|Running"
kubectl describe <kind>/<name> -n toolhive-system | tail -30
kubectl get pods -n toolhive-system | grep -vE "Running|Completed"
```

For pull errors, check disk (`docker system df`) and consider `docker
system prune` if it's tight.

### LibreChat: "Too many login attempts, please try again after 5 minutes"

**Why.** LibreChat's built-in rate limiter counts any OIDC round-trip as
a login attempt. Even with the demo-friendly ceilings in
`addons/librechat/values.yaml` (`LOGIN_MAX=100` per 5 minutes), fast
cycling through the demo personas during a presentation can trip it —
and the counter is in-memory.

**Fix.** Restart the LibreChat pod to reset the counter:

```sh
kubectl rollout restart deployment/librechat -n librechat
```

---

## Useful commands

Kubernetes context is the one `kind create cluster` wrote — usually
`kind-toolhive-demo-in-a-box`. If you've got other clusters in your
kubeconfig, `kubectl config use-context kind-toolhive-demo-in-a-box`
before the snippets below, or point at the repo-local copy with
`export KUBECONFIG=$(pwd)/kubeconfig-toolhive-demo.yaml`.

Every snippet assumes the hostname preamble:

```sh
# Derive the current hostnames (everything is IP-based via traefik.me).
TRAEFIK_IP=$(kubectl get gateways -n traefik traefik-gateway \
    -o jsonpath='{.status.addresses[0].value}')
BASE=${TRAEFIK_IP//./-}.traefik.me
AUTH=auth-$BASE       # Keycloak
REG=registry-$BASE    # Registry server
UI=ui-$BASE           # Cloud UI
CHAT=chat-$BASE       # LibreChat (if addon installed)
```

### Mint a user token for curl testing

The `toolhive-cloud-ui` client has `directAccessGrantsEnabled: true`, so
we can skip the browser flow:

```sh
TOKEN=$(curl -sk -X POST \
    "https://$AUTH/realms/toolhive-demo/protocol/openid-connect/token" \
    -d "grant_type=password&client_id=toolhive-cloud-ui&client_secret=cloud-ui-secret-change-in-production&username=demo&password=demo&scope=openid" \
    | python3 -c "import sys,json; print(json.load(sys.stdin)['access_token'])")

# Decode the claims
python3 -c "
import base64, json
payload = '$TOKEN'.split('.')[1] + '=='
print(json.dumps(json.loads(base64.urlsafe_b64decode(payload)), indent=2))"
```

Swap `demo/demo` for `alice/alice` or `bob/bob` to test persona-specific
visibility.

### List registry entries visible to a persona

```sh
curl -s "http://$REG/registry/demo-registry/v0.1/servers?limit=200" \
    -H "Authorization: Bearer $TOKEN" \
    | python3 -c "import sys,json; print('\n'.join(sorted(
        s['server']['name'] for s in json.load(sys.stdin)['servers'])))"
```

### Patch Keycloak client redirect URIs in place

Quick recovery for an IP drift mid-demo, if re-bootstrapping is
inconvenient:

```sh
ADMIN_TOKEN=$(curl -sk -X POST \
    "https://$AUTH/realms/master/protocol/openid-connect/token" \
    -d "grant_type=password&client_id=admin-cli&username=admin&password=admin" \
    | python3 -c "import sys,json; print(json.load(sys.stdin)['access_token'])")

CLIENT_ID=$(curl -sk \
    "https://$AUTH/admin/realms/toolhive-demo/clients?clientId=toolhive-cloud-ui" \
    -H "Authorization: Bearer $ADMIN_TOKEN" \
    | python3 -c "import sys,json; print(json.load(sys.stdin)[0]['id'])")

curl -sk -X PUT \
    "https://$AUTH/admin/realms/toolhive-demo/clients/$CLIENT_ID" \
    -H "Authorization: Bearer $ADMIN_TOKEN" -H "Content-Type: application/json" \
    -d "{\"redirectUris\":[\"https://$UI/api/auth/oauth2/callback/keycloak\",\"https://$UI/api/auth/callback/keycloak\",\"http://localhost:3000/*\"]}"
```

Repeat for each stale client (`librechat`, etc.). Re-run
`./bootstrap.sh` later to let the drift-detection re-stamp the state
durably.

### Inspect a vMCP's operator-rendered config

When something's off with a `VirtualMCPServer`, the fastest way to see
what the operator actually handed the vmcp binary is to read the
generated ConfigMap:

```sh
kubectl get configmap <vmcp-name>-vmcp-config -n toolhive-system \
    -o jsonpath='{.data.config\.yaml}'
```

### List a vMCP's discovered backends

```sh
kubectl get vmcp <vmcp-name> -n toolhive-system \
    -o jsonpath='{.status.discoveredBackends[*].name}'
```

### Validate manifest changes against the live CRDs

```sh
# Only files changed vs HEAD.
.claude/skills/validate-manifests/scripts/validate.sh

# Specific files.
.claude/skills/validate-manifests/scripts/validate.sh demo-manifests/vmcp-infra.yaml

# Every YAML under demo-manifests/, addons/, infra/.
.claude/skills/validate-manifests/scripts/validate.sh --all
```

### Nuke everything and start over

```sh
./cleanup.sh && ./bootstrap.sh
```
