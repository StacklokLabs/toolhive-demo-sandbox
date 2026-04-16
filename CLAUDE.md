# CLAUDE.md

Guidance for Claude Code when working in this repo. Complements `README.md` (user-facing) and your memory notes (preferences).

## What this repo is

A self-contained ToolHive-on-Kubernetes demo sandbox driven by `./bootstrap.sh`. Creates a kind cluster, deploys the ToolHive operator + registry server + cloud-UI + Keycloak, plus a set of persona-scoped MCP groups and vMCP gateways. Targets demoing the platform, not production.

## Repo layout

```
bootstrap.sh               # one-shot cluster bring-up; idempotent
cleanup.sh                 # tears down the kind cluster
validate.sh                # post-bootstrap endpoint checks (reads demo-endpoints.json)
helpers.sh                 # run_quiet / die / wait_for_pods_ready
kind-config.yaml           # kind cluster definition
infra/                     # cluster-level infra: traefik, o11y, keycloak, registry DB
demo-manifests/            # ToolHive resources (MCPGroups, MCPServers, vMCPs, registry config)
addons/                    # opt-in extras (librechat, cloud-ui-openrouter, vmcp-infra-okta, ...)
  _lib.sh                  # shared addon framework (addon_load_env, addon_apply, ...)
  _template/               # starting point for new addons
local-demos/               # ad-hoc one-offs, not part of the mainline bootstrap
```

## Personas and the group/vMCP model

Demo users come from Keycloak (`infra/keycloak.yaml`): `demo` (all groups, registry superAdmin), `alice` (engineering), `bob` (finance). Registry-side authz is driven by group claims on catalog sources (`demo-manifests/registry-server-helm-values.yaml`) and by `toolhive.stacklok.dev/authz-claims` annotations on in-cluster resources.

Current shape (as of this writing — grep the manifests to confirm):

| MCPGroup | Backends | vMCP front-end | Audience |
|---|---|---|---|
| `infra-tools` | prometheus, grafana, osv, oci-registry, mkp | `vmcp-infra`, `vmcp-infra-optimized` | engineering |
| `shared-tools` | fetch, context7, toolhive-docs (MCPRemoteProxy) | `vmcp-docs` | everyone |
| `finance-tools` | finance-fetch (stub) | `vmcp-finance` | finance |
| `research-tools` | arxiv | `vmcp-research` | everyone |

A single MCPServer/MCPRemoteProxy belongs to exactly one MCPGroup. Multiple vMCPs can share a groupRef (e.g. `vmcp-infra` and `vmcp-infra-optimized` both aggregate `infra-tools`).

## Annotations that matter

On MCPServer / MCPRemoteProxy / VirtualMCPServer, the registry-server's K8s source reads:

- `toolhive.stacklok.dev/registry-export: "true"` — include in the registry (absence = excluded)
- `toolhive.stacklok.dev/registry-url` — public URL, usually `http://$MCP_HOSTNAME/<path>/mcp` for local, external domain for tunnel-fronted
- `toolhive.stacklok.dev/registry-title` / `registry-description`
- `toolhive.stacklok.dev/authz-claims: '{"groups": "engineering"}'` — gates visibility in authenticated registry entries
- `toolhive.stacklok.dev/tool-definitions` — JSON list (name + description) shown in the registry; must be kept in sync with filtered/aggregated tools or the UI lies

`MCPServerEntry` is **not** picked up by registry-server v1.1.2's K8s source (it's a vMCP backend-discovery mechanism, not a catalog-publication mechanism). Use `MCPRemoteProxy` with registry-export when you want a remote server to appear in the registry.

## Bootstrap order — don't reorder without care

The registry server installs **after** all MCPGroups / MCPServers / VirtualMCPServers / MCPRemoteProxies are Ready. Earlier ordering (registry first, MCP resources later) caused SQLSTATE 40001 serialization storms where the K8s reconciler upserts raced git-source commits on the same serializable transactions, and sometimes starved entire git sources out. Keep the current "everything MCP, then registry, then cloud-UI" sequence.

`set -a` at the top of `bootstrap.sh` auto-exports every assignment so child `envsubst`/`helm` processes see them. The `envsubst '$REGISTRY_HOSTNAME $AUTH_HOSTNAME' < file` form only substitutes the listed vars — forgetting to export them yields empty strings and a broken helm-values file.

## Addons framework

Each dir under `addons/` is a self-contained opt-in feature. Use `addons/_template/` as a starting point and `addons/_lib.sh` for helpers:

- `addon_load_env` — `.env` in addon dir wins, else repo root
- `addon_require_env FOO` — die with a pointer to `.env` if unset
- `addon_resolve_traefik` — sets `TRAEFIK_IP` / `TRAEFIK_HOSTNAME_BASE`
- `addon_create_namespace` / `addon_delete_namespace` — default to `$ADDON_NAME`
- `addon_apply <file>` — runs envsubst iff the file contains `$`, else plain apply
- `addon_wait_ready <label> [ns] [timeout]` — waits for at least one matching pod then waits ready

Each addon ships `deploy.sh`, `teardown.sh`, `README.md`, and a `.env.example` listing required vars. Don't invent parallel patterns; extend `_lib.sh` if something's missing.

## Operator v0.21.0 breaking changes to watch for

- MCPServer / MCPRemoteProxy: inline `spec.telemetry` is gone. Use `telemetryConfigRef` pointing at an MCPTelemetryConfig (shared one is `shared-otel` in `demo-manifests/mcp-telemetry-config.yaml`). Note: vMCP still allows inline `config.telemetry`.
- MCPServer / MCPRemoteProxy: inline `spec.oidcConfig` is gone. Use `oidcConfigRef` → MCPOIDCConfig.
- VirtualMCPServer: inline `spec.incomingAuth.oidcConfig` is gone. Use `spec.incomingAuth.oidcConfigRef.name` + `audience` + `resourceUrl` at the ref level; provider settings go in a sibling MCPOIDCConfig (see `addons/vmcp-infra-okta/vmcp.yaml` for a working example).
- VirtualMCPServer: `spec.config.groupRef` fallback is gone. Only `spec.groupRef` is honoured.

When a new operator version lands, check `gh release view vX.Y.Z --repo stacklok/toolhive` for migration guides before bumping in `bootstrap.sh`.

## Optimizer + embeddings

`vmcp-infra-optimized` demonstrates the vMCP-integrated optimizer. It references a shared `EmbeddingServer` (`demo-manifests/embedding-server.yaml`) whose image tag is selected per host arch in `bootstrap.sh` (`cpu-arm64-latest` on Apple Silicon, `cpu-latest` elsewhere). Adding `spec.embeddingServerRef.name` to any vMCP makes it expose only `find_tool` and `call_tool`. The legacy standalone `mcp-optimizer` Helm chart is gone — don't bring it back.

## Cloudflare tunnels (addons that need real HTTPS)

Addons like `vmcp-infra-okta` are fronted by an externally-configured Cloudflare tunnel. The tunnel's ingress rule maps `public-hostname → Service` and lives in the Cloudflare dashboard, **not in code**. When the target Service name changes (e.g. renaming a vMCP), the tunnel's ingress rule must be updated in the dashboard — cloudflared picks up within seconds, no pod restart needed.

## Quick verification commands

Get a bearer token and hit the authenticated registry as `demo`:

```sh
export KUBECONFIG=$(pwd)/kubeconfig-toolhive-demo.yaml
TRAEFIK_IP=$(kubectl get gateways --namespace traefik traefik-gateway -o jsonpath='{.status.addresses[0].value}')
AUTH=auth-${TRAEFIK_IP//./-}.traefik.me
REG=registry-${TRAEFIK_IP//./-}.traefik.me
TOKEN=$(curl -sk -X POST "https://$AUTH/realms/toolhive-demo/protocol/openid-connect/token" \
  -d "grant_type=password&client_id=toolhive-cloud-ui&client_secret=cloud-ui-secret-change-in-production&username=demo&password=demo&scope=openid" \
  | python3 -c "import sys,json; print(json.load(sys.stdin)['access_token'])")
curl -s "http://$REG/registry/demo-registry/v0.1/servers?limit=200" -H "Authorization: Bearer $TOKEN" \
  | python3 -c "import sys,json; print('\n'.join(sorted({s['server']['name'] for s in json.load(sys.stdin)['servers']})))"
```

Inspect vMCP backend discovery:

```sh
kubectl get vmcp <name> -n toolhive-system -o jsonpath='{.status.discoveredBackends[*].name}'
```

## Editing checklist

When touching `demo-manifests/`, think about:

1. Does the change need a corresponding update to `bootstrap.sh` (apply order, wait targets, endpoint JSON, final URL echo)?
2. If a resource has `registry-export=true`, is the `tool-definitions` annotation still accurate for the filtered tool set?
3. Is `authz-claims` consistent with the persona access story in `README.md`?
4. For vMCPs that aggregate: do the workload names in `aggregation.tools` match actual MCPServer/MCPRemoteProxy names in the group?
5. Any manifest with `$VARS` must be rendered via `envsubst` (see patterns in `bootstrap.sh` and `addon_apply`).

## Conventions & preferences (from memory — re-read as needed)

- Prefer Context7 MCP (`mcp__context7__query-docs`) over WebFetch for library docs.
- Prefer `mcp__toolhive-doc-mcp__query_docs` for ToolHive-specific docs; fall back to WebFetch only for pages not yet indexed.
- Prefer `skopeo list-tags` over `docker manifest inspect` for inspecting images.
- Disable Bitnami subcharts; pull upstream images instead (they're often unreliable in the Bitnami variant).
- User prefers small, surgical commits; don't pile unrelated changes together.
