# vmcp-infra-okta

Authenticated mirror of the infra vMCP gateway, with **tiered per-tool authorization** driven by Okta group claims. Same Prometheus / Grafana / OSV / OCI / MKP backends as `vmcp-infra`, fronted by ToolHive's embedded OAuth authorization server (which delegates to Okta) and exposed externally over HTTPS via a Cloudflare tunnel.

## What it does

- Deploys a `VirtualMCPServer` named `vmcp-infra-okta` aggregating the `infra-tools` group
- Embedded auth server delegates authentication to Okta
- Publishes the gateway at `https://<your-domain>/mcp` via a Cloudflare tunnel
- Cedar authorization policy filters tools per caller based on Okta group membership

Sits **alongside** the existing unauthenticated `vmcp-infra` for a clean compare-and-contrast.

## Authorization tiers

The shipped Cedar policy (`spec.incomingAuth.authzConfig` in [vmcp.yaml](vmcp.yaml)) defines two tiers:

| Tier            | Okta group    | Tools visible                                                                                                                                          |
| --------------- | ------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------ |
| **Engineering** | `Engineering` | All 33 aggregated tools, including raw Prometheus queries, OSV vulnerability lookups, OCI registry inspection, and the mutating MKP (Kubernetes) tools |
| **Support**     | `Support`     | Only the curated Grafana dashboard layer (`grafana_*`)                                                                                                 |

Because Cedar filters `tools/list` responses through the same `call_tool` policy used for invocation, **users only see the tools they're allowed to call** in the first place. Support-tier users don't see `prometheus_*`, `mkp_*`, etc. at all. A direct call to a tool outside your tier returns 403.

A user in neither group gets no tools at all — both tiers require explicit group membership. Create `Engineering` and `Support` groups in Okta and assign your demo users to one each.

## Prerequisites

- Demo sandbox cluster running (`bootstrap.sh` completed)
- An Okta authorization server + OIDC application configured (see below)
- A Cloudflare tunnel configured (see below) and a domain under your control

## Okta setup

In the [Okta admin console](https://integrator-9462356-admin.okta.com/):

1. **Authorization Server** — Security → API → Authorization Servers → Add:
   - **Name**: e.g. `vMCP Infra Auth`
   - **Audience**: a generic, stable value, e.g. `api://toolhive-vmcp-demo` (doesn't need to match your tunnel hostname — ToolHive never validates it)

2. **Groups claim on the access token** — required so Cedar can evaluate group membership. On the authorization server you just created, open the **Claims** tab → **Add Claim**:
   - **Name**: `groups`
   - **Include in token type**: Access Token (request)
   - **Value type**: Groups
   - **Filter**: `Matches regex` `^(Engineering|Support)$` (both tiers require explicit membership, so there's no need to admit every group into the token)
   - **Include in**: Any scope

   Use the **Token Preview** tab to verify the resulting access token carries the `groups` claim before deploying.

3. **Application** — Applications → Create App Integration:
   - **Sign-in method**: OIDC
   - **Application type**: Web Application
   - **Grant type**: Authorization Code
   - **Sign-in redirect URI**: `https://<your-subdomain>.stacklok-demo.com/oauth/callback`
   - **Assignments**: your demo users/groups

4. Capture:
   - **Client ID** and **Client Secret** from the application
   - **Issuer URL** from the authorization server (e.g. `https://integrator-XXXXXXX.okta.com/oauth2/ausXXXXXXXX`)

## Cloudflare tunnel setup

In the [Cloudflare dashboard](https://one.dash.cloudflare.com/), create a tunnel:

- **Subdomain**: e.g. `<name>-vmcp-infra-okta`
- **Domain**: `stacklok-demo.com` (or any domain you control)
- **Path**: (empty — all paths must route, including `/oauth/callback`)
- **Service Type**: `HTTP`
- **Service URL**: `vmcp-vmcp-infra-okta.mcp-workloads.svc.cluster.local:4483`

Copy the tunnel token.

## Deploy

```bash
cp .env.example .env   # then fill in the Okta + tunnel values
./deploy.sh
```

## Teardown

```bash
./teardown.sh
```

## Verify

```bash
kubectl get virtualmcpserver vmcp-infra-okta -n mcp-workloads
kubectl get pods -n vmcp-infra-okta
```

Then test with the ToolHive CLI as two different users. Use distinct workload names so credentials don't collide:

```bash
# Engineering-tier user
thv run --name vmcp-infra-okta-eng --transport streamable-http https://<your-subdomain>.stacklok-demo.com/mcp
# Sign in as a user in the Engineering Okta group; expect all 33 tools in tools/list.

# Support-tier user
thv run --name vmcp-infra-okta-support --transport streamable-http https://<your-subdomain>.stacklok-demo.com/mcp
# Sign in as a user in the Support Okta group; expect only ~15 grafana_* tools.
```

Direct calls to non-permitted tools (e.g. `mkp_apply_resource` as a Support-tier user) return 403. Cedar deny decisions land in the vMCP pod logs and the workflow audit log.

## Configuration

- [vmcp.yaml](vmcp.yaml) — VirtualMCPServer: auth config, **Cedar policy**, registry annotations, aggregation filters
- [cloudflared.yaml](cloudflared.yaml) — tunnel Deployment (namespace `vmcp-infra-okta`)

## Tweaking the policy

The Cedar policies live inline in `vmcp.yaml` under `spec.incomingAuth.authzConfig.inline.policies`. Some common adjustments:

- **Add more tiers**: a new permit rule keyed on a different `THVGroup::"..."` value (e.g. `Security` → `osv_*` and `oci-registry_*` only).
- **Rename groups**: Cedar entity IDs are case-sensitive — `THVGroup::"Engineering"` matches the Okta group named exactly `Engineering`.
- **Change the Support tool set**: edit the `like "grafana_*"` pattern. Cedar's `like` supports `*` as a wildcard. To match multiple prefixes, use multiple permit rules.

After editing, re-apply `vmcp.yaml` — the operator rolls the vMCP pod and the new policy takes effect on the next request.
