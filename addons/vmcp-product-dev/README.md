# vmcp-product-dev

Product development vMCP gateway aggregating **GitLab's official remote MCP server** (`https://gitlab.com/api/v4/mcp`). Fronted by ToolHive's embedded OAuth authorization server (which delegates identity to Entra ID) and exposed externally over HTTPS via a Cloudflare tunnel.

The addon owns its own `product-dev-tools` MCPGroup, so it's the place to grow a product-development backend stack (issue trackers, CI, code hosting) over time.

## What it does

- Creates the `product-dev-tools` MCPGroup with a zero-infrastructure `gitlab` MCPServerEntry pointing at `gitlab.com/api/v4/mcp`
- Deploys a `VirtualMCPServer` named `vmcp-product-dev` aggregating that group, with audit logging and OTel telemetry (`shared-otel`) enabled
- Embedded auth server delegates authentication to Entra ID (identity), then to GitLab (per-user API token) in a single sequential login flow
- Registers the gateway's OAuth client with GitLab at runtime via **RFC 7591 Dynamic Client Registration**, so there is no GitLab OAuth app to pre-register
- Publishes the gateway at `https://<your-domain>/mcp` via a Cloudflare tunnel, and exports it to the demo registry (visible to the `engineering` group)

## How the auth flow works

GitLab's MCP server is not federated with Entra ID, so a single Entra token can't reach it. The embedded auth server bridges the two:

1. The MCP client discovers the vMCP's authorization server and registers (or identifies) itself.
2. On authorize, the user first signs in to **Entra ID**. This is the identity leg: the vMCP-issued JWT's subject comes from here.
3. The flow then chains to **GitLab**: the user approves the DCR-registered client with scope `mcp`. The resulting GitLab token is stored against the user and upstream-injected into every request the vMCP proxies to `gitlab.com/api/v4/mcp`.
4. The client receives a vMCP-issued token; each user's GitLab actions run under their own GitLab identity.

The GitLab provider deliberately has no `userInfo` config. Identity is already resolved by the Entra leg, so the GitLab leg runs in identity-synthesis mode and is used purely for token acquisition (the vmcp pod logs a one-time WARN about this; it's expected).

### DCR caveats (demo trade-offs)

- No persistent storage backend is configured, so the DCR-issued client and all user tokens live in pod memory. A vMCP pod restart registers a **fresh** OAuth client with gitlab.com (the old one is orphaned there) and every user re-authenticates.
- `scopes: [mcp]` on the GitLab provider must stay explicit. If left empty, the client would be registered with GitLab's entire `scopes_supported` list while authorize requests go out with an empty `scope` parameter.

## Prerequisites

- Demo sandbox cluster running (`bootstrap.sh` completed)
- An Entra ID app registration (see below)
- A Cloudflare tunnel configured (see below) and a domain under your control
- A gitlab.com account for each demo user, with MCP server access enabled (see [GitLab setup](#gitlab-setup))

## Entra ID setup

Follow the same shape as the [ToolHive Entra ID integration docs](https://docs.stacklok.com/toolhive/integrations/vmcp-entra-id). In the Entra admin portal:

1. **App registration** — Entra ID → App registrations → New registration:
   - **Name**: e.g. `vMCP Product Dev`
   - **Supported account types**: Single tenant
   - **Redirect URI**: platform **Web**, value `https://<your-domain>/oauth/callback`

   Capture the **Application (client) ID** and **Directory (tenant) ID** from the Overview page. An existing app registration for another vMCP gateway also works; just add this addon's redirect URI to it.

2. **Expose an API** — your app → Expose an API:
   - Click **Add** next to "Application ID URI" and accept the default `api://<CLIENT_ID>`
   - **Add a scope**: name `mcp.access`, state **Enabled** (the vMCP requests `api://<CLIENT_ID>/mcp.access`)

3. **Require assignment** — Entra ID → Enterprise applications → your app → Properties → **Assignment required?** → **Yes**, then assign your demo users under **Users and groups**. This ensures only explicitly assigned users can sign in.

4. **Client secret** — your app → Certificates & secrets → New client secret. Copy the **Value** immediately (it's only shown once).

Capture for the `.env`:

- Application (client) ID → `VMCP_ENTRA_CLIENT_ID`
- Client secret value → `VMCP_ENTRA_CLIENT_SECRET`
- Issuer URL → `ENTRA_ISSUER_URL=https://login.microsoftonline.com/<TENANT-ID>/v2.0`

## GitLab setup

There is no OAuth application to register: GitLab supports Dynamic Client Registration (`https://gitlab.com/oauth/register`, advertised in its discovery document), and the embedded auth server registers its client automatically at startup. On the consent screen the client appears as `[Unverified Dynamic Application] ToolHive MCP Client`, which is GitLab's standard labeling for DCR-registered clients.

What each demo user *does* need is [MCP server access](https://docs.gitlab.com/user/model_context_protocol/mcp_server/), which GitLab.com gates on top-level group settings:

1. The account must belong to a **top-level group**. A personal namespace alone doesn't qualify; creating a Free group works (GitLab 19.2 moved the MCP setting to the Free tier).
2. In that group: **Settings → General → Permissions and group features**, enable **MCP client access**, and save.

If this is missing, the OAuth flow completes normally but every MCP call returns `404 {"message":"404 Not Found"}` (see [GitLab's MCP troubleshooting doc](https://docs.gitlab.com/user/gitlab_duo/model_context_protocol/mcp_server_troubleshooting/)). Since unauthenticated requests get a 401 instead, a 404 with a valid token means this account gate, not a gateway problem.

Once access works, the tools operate on whatever the signed-in user can reach, including personal-namespace projects.

## Cloudflare tunnel setup

In the [Cloudflare dashboard](https://one.dash.cloudflare.com/), create a tunnel:

- **Subdomain**: e.g. `<name>-vmcp-product-dev`
- **Domain**: `stacklok-demo.com` (or any domain you control)
- **Path**: (empty, all paths must route, including `/oauth/callback`)
- **Service Type**: `HTTP`
- **Service URL**: `vmcp-vmcp-product-dev.mcp-workloads.svc.cluster.local:4483`

Copy the tunnel token.

## Deploy

```bash
cp .env.example .env   # then fill in the Entra ID + tunnel values
./deploy.sh
```

## Teardown

```bash
./teardown.sh
```

## Verify

```bash
kubectl get virtualmcpserver vmcp-product-dev -n mcp-workloads
kubectl get vmcp vmcp-product-dev -n mcp-workloads -o jsonpath='{.status.discoveredBackends[*].name}'
kubectl get pods -n vmcp-product-dev
```

Then connect with the ToolHive CLI:

```bash
thv run --name vmcp-product-dev --transport streamable-http https://<your-subdomain>.stacklok-demo.com/mcp
```

The browser flow signs you in to Entra ID first, then GitLab. Expect the GitLab tools (prefixed `gitlab_*`) in `tools/list`; try `gitlab_get_mcp_server_version` for a no-argument smoke test, or `gitlab_search` against a project you can access.

Audit events land on the vmcp pod stdout as `{"level":"AUDIT"}` JSON, and traces/metrics flow to the shared observability stack via the `shared-otel` MCPTelemetryConfig.

## Configuration

- [product-dev-tools.yaml](product-dev-tools.yaml): the MCPGroup, the `gitlab` MCPServerEntry, and the upstream-inject MCPExternalAuthConfig
- [vmcp.yaml](vmcp.yaml): VirtualMCPServer (auth server + upstream providers, registry annotations, audit/telemetry) and its MCPOIDCConfig verifier
- [cloudflared.yaml](cloudflared.yaml): tunnel Deployment (namespace `vmcp-product-dev`)

### Adding a backend

Add an MCPServer or MCPServerEntry with `spec.groupRef.name: product-dev-tools` in `mcp-workloads` (grow `product-dev-tools.yaml` or drop in a new file applied by `deploy.sh`). For remotes needing their own OAuth: add an upstream provider to `vmcp.yaml`'s `authServerConfig.upstreamProviders`, an `MCPExternalAuthConfig` of type `upstreamInject`, and a `spec.outgoingAuth.backends` entry mapping the backend name to it. Update the `tool-definitions` annotation to match the new aggregate tool set.

### Known gaps

- **No per-tool authorization**: every authenticated Entra user sees every aggregated tool. Authentication is the only gate (plus Entra's "Assignment required?" controlling who can sign in at all).
- **tool-definitions drift**: the registry annotation in `vmcp.yaml` reflects the GitLab MCP tool list as documented (GitLab 18.3 through 19.2). GitLab.com ships continuously; resync the annotation against a live `tools/list` after connecting.
