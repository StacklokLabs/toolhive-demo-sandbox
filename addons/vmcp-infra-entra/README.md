# vmcp-infra-entra

Authenticated mirror of the infra vMCP gateway, with **tiered per-tool authorization** driven by Entra ID app-role claims. Same Prometheus / Grafana / OSV / OCI / MKP backends as `vmcp-infra`, fronted by ToolHive's embedded OAuth authorization server (which delegates to Entra ID) and exposed externally over HTTPS via a Cloudflare tunnel.

## What it does

- Deploys a `VirtualMCPServer` named `vmcp-infra-entra` aggregating the `infra-tools` group
- Embedded auth server delegates authentication to Entra ID
- Publishes the gateway at `https://<your-domain>/mcp` via a Cloudflare tunnel
- Cedar authorization policy filters tools per caller based on Entra ID app-role assignments

Sits **alongside** the existing unauthenticated `vmcp-infra` for a clean compare-and-contrast.

## Authorization tiers

The shipped Cedar policy (`spec.incomingAuth.authzConfig` in [vmcp.yaml](vmcp.yaml)) defines two tiers, each keyed on an Entra ID app role:

| Tier            | App role value    | Tools visible                                                                                                                                          |
| --------------- | ----------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------ |
| **Engineering** | `mcp-engineering` | All 33 aggregated tools, including raw Prometheus queries, OSV vulnerability lookups, OCI registry inspection, and the mutating MKP (Kubernetes) tools |
| **Baseline**    | `mcp-finance`     | Only the curated Grafana dashboard layer (`grafana_*`), and only the read-only ones                                                                    |

Because Cedar filters `tools/list` responses through the same `call_tool` policy used for invocation, **users only see the tools they're allowed to call** in the first place. Baseline users don't see `prometheus_*`, `mkp_*`, etc. at all. A direct call to a tool outside your tier returns 403.

Entra ID emits app-role assignments in the `roles` claim on the access token. The vMCP is configured (via `primaryUpstreamProvider: entra` on the Cedar authz config) to evaluate `THVGroup` membership from that claim, so an app role value like `mcp-engineering` is what Cedar matches against.

## Prerequisites

- Demo sandbox cluster running (`bootstrap.sh` completed)
- An Entra ID app registration (see below)
- A Cloudflare tunnel configured (see below) and a domain under your control

## Entra ID setup

Follow the same shape as the [ToolHive Entra ID integration docs](https://docs.stacklok.com/toolhive/integrations/vmcp-entra-id). In the Entra admin portal:

1. **App registration** — Entra ID → App registrations → New registration:
   - **Name**: e.g. `vMCP Infra Entra`
   - **Supported account types**: Single tenant
   - **Redirect URI**: platform **Web**, value `https://<your-subdomain>.stacklok-demo.com/oauth/callback`

   Capture the **Application (client) ID** and **Directory (tenant) ID** from the Overview page.

2. **Expose an API** — your app → Expose an API:
   - Click **Add** next to "Application ID URI" and accept the default `api://<CLIENT_ID>`
   - **Add a scope**:
     - Scope name: `mcp.access`
     - Admin consent display name: `Access MCP Servers`
     - State: **Enabled**

3. **Require assignment** — Entra ID → Enterprise applications → your app → Properties:
   - **Assignment required?** → **Yes**

   This prevents any tenant user from authenticating; only users explicitly assigned to an app role can sign in.

4. **App roles** — your app → App roles → Create app role. Create both roles below. The **Value** fields must match the Cedar policy in [vmcp.yaml](vmcp.yaml) exactly (case-sensitive):

   | Display name    | Value             | Allowed member types |
   | --------------- | ----------------- | -------------------- |
   | MCP Engineering | `mcp-engineering` | Users/Groups         |
   | MCP Finance     | `mcp-finance`     | Users/Groups         |

5. **Assign users to roles** — Enterprise applications → your app → Users and groups → Add user/group:
   - Pick a user (or security group)
   - **Select a role** — pick `MCP Engineering` or `MCP Finance` (do **not** leave it on `Default Access`)
   - **Assign**

   Repeat for each demo user. A given user can only hold one role on this app at a time, so assign them separately if you want to demo a role switch.

6. **Client secret** — your app → Certificates & secrets → Client secrets → New client secret:
   - Set an expiry
   - Copy the **Value** immediately (it's only shown once) — this is `VMCP_ENTRA_CLIENT_SECRET`

7. **Optional claims** — your app → Token configuration → Add optional claim:
   - Token type: **ID**
   - Check: `email`, `given_name`, `family_name`

8. Capture for the `.env`:
   - **Client ID** (Application (client) ID) → `VMCP_ENTRA_CLIENT_ID`
   - **Client Secret** value → `VMCP_ENTRA_CLIENT_SECRET`
   - **Issuer URL** → `ENTRA_ISSUER_URL=https://login.microsoftonline.com/<TENANT-ID>/v2.0`

## Cloudflare tunnel setup

In the [Cloudflare dashboard](https://one.dash.cloudflare.com/), create a tunnel:

- **Subdomain**: e.g. `<name>-vmcp-infra-entra`
- **Domain**: `stacklok-demo.com` (or any domain you control)
- **Path**: (empty, all paths must route, including `/oauth/callback`)
- **Service Type**: `HTTP`
- **Service URL**: `vmcp-vmcp-infra-entra.mcp-workloads.svc.cluster.local:4483`

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
kubectl get virtualmcpserver vmcp-infra-entra -n mcp-workloads
kubectl get pods -n vmcp-infra-entra
```

Then test with the ToolHive CLI as two different users. Use distinct workload names so credentials don't collide:

```bash
# Engineering-tier user (assigned to the mcp-engineering app role)
thv run --name vmcp-infra-entra-eng --transport streamable-http https://<your-subdomain>.stacklok-demo.com/mcp
# Expect all 33 tools in tools/list.

# Baseline user (assigned to the mcp-finance app role)
thv run --name vmcp-infra-entra-baseline --transport streamable-http https://<your-subdomain>.stacklok-demo.com/mcp
# Expect only the read-only grafana_* tools.
```

Direct calls to non-permitted tools (e.g. `mkp_apply_resource` as a baseline user) return 403. Cedar deny decisions land in the vMCP pod logs and the workflow audit log.

## Configuration

- [vmcp.yaml](vmcp.yaml), VirtualMCPServer: auth config, **Cedar policy**, registry annotations, aggregation filters
- [cloudflared.yaml](cloudflared.yaml), tunnel Deployment (namespace `vmcp-infra-entra`)

## Tweaking the policy

The Cedar policies live inline in `vmcp.yaml` under `spec.incomingAuth.authzConfig.inline.policies`. Some common adjustments:

- **Add more tiers**: create a new app role in Entra ID (e.g. `mcp-security`) and a matching permit rule keyed on `THVGroup::"mcp-security"` scoped to whichever tools that tier should reach (e.g. `osv_*` and `oci-registry_*`).
- **Rename roles**: Cedar entity IDs are case-sensitive. `THVGroup::"mcp-engineering"` matches the app role whose **Value** is exactly `mcp-engineering`. Rename in both places together.
- **Change the baseline tool set**: edit the `like "grafana_*"` pattern. Cedar's `like` supports `*` as a wildcard. To match multiple prefixes, use multiple permit rules.
- **Open the baseline to everyone in the tenant**: app-role claims aren't emitted for users without an assignment, and "Assignment required?" blocks unassigned users entirely. If you want a true "any signed-in user" baseline, flip "Assignment required?" off and gate the Cedar baseline on a different claim (e.g. a `groups` claim configured via Token configuration → Add groups claim) instead of an app role.

After editing, re-apply `vmcp.yaml`. The operator rolls the vMCP pod and the new policy takes effect on the next request.
