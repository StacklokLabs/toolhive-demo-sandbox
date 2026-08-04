# LibreChat

Deploys [LibreChat](https://www.librechat.ai/) as a chat UI connected to the demo sandbox's vMCP gateway over streamable-http.

## What it does

- Installs LibreChat via the official Helm chart (includes MongoDB)
- Authenticates users via the sandbox's Keycloak realm (`toolhive-demo`); local
  email/password login and self-registration are disabled
- Creates an in-cluster `vmcp-chat` VirtualMCPServer (aggregating the
  `infra-tools` group) that validates Keycloak-issued user tokens on the
  `toolhive-vmcp-chat` audience, and wires LibreChat to forward the
  logged-in user's access token on every MCP call
- Exposes the `audit_image_supply_chain` and `mcp_server_pulse` composite
  tools through that same authenticated gateway, by referencing the shared
  `VirtualMCPCompositeToolDefinition` resources `vmcp-platform` also uses —
  and uses them to show a lower-privilege tier reaching a capability it has
  no direct access to
- Also connects to `vmcp-docs` (anonymous, shared docs tools)
- Routes through OpenRouter for LLM inference (multi-model)
- Pre-seeds a publicly shared "Infra Agent" wired to the vMCPs, so every
  persona has a ready-to-chat agent on first login

## Prerequisites

- Demo sandbox cluster running (`bootstrap.sh` completed)
- An [OpenRouter](https://openrouter.ai/) API key

## Deploy

```bash
cp .env.example .env   # then fill in your OpenRouter key
./deploy.sh
```

The script prints the URL and login credentials when done.

Sign in using any Keycloak realm user — `demo` / `demo`, `alice` / `alice`, or
`bob` / `bob`. First login auto-provisions the corresponding LibreChat account.

> The Keycloak client for LibreChat is registered in `infra/keycloak.yaml` with
> a fixed redirect URI derived from the Traefik LB IP, so this addon only works
> against a sandbox cluster bootstrapped from that manifest (i.e. via
> `bootstrap.sh`).

## Teardown

```bash
./teardown.sh
```

Removes all resources including the Helm release, namespace, and persistent volumes.

## Configuration

- [values.yaml](values.yaml) — Helm values (LibreChat config, models, MCP endpoints, allowed domains, OIDC env)
- [vmcp-chat.yaml](vmcp-chat.yaml) — authenticated VirtualMCPServer over `infra-tools`
- [vmcp-chat-authz.yaml](vmcp-chat-authz.yaml) — Cedar policies gating `tools/list` + `tools/call` by the Keycloak `groups` claim (engineering: full access; finance/support: read-only observability, scoped by prefix + `readOnlyHint`)
- [httproute.yaml](httproute.yaml) — Gateway API route (the chart uses Ingress which we replace with HTTPRoute)
- [infra-agent.json](infra-agent.json) — payload for the pre-seeded "Infra Agent" (POSTed to `/api/agents` on deploy if not already present)

The deploy script injects the per-cluster `OPENID_ISSUER`, mirrors the Traefik
CA into the `librechat` namespace (so the Node runtime trusts the self-signed
Keycloak cert via `NODE_EXTRA_CA_CERTS`), and provisions the OIDC client secret
that matches the `librechat` client declared in `infra/keycloak.yaml`.

## How authentication flows

1. User hits `https://chat-<traefik-ip>.sslip.io`; LibreChat auto-redirects
   to Keycloak (`OPENID_AUTO_REDIRECT=true`).
2. After Keycloak auth, LibreChat receives an access token whose `aud` claim
   includes `toolhive-vmcp-chat` (via the `mcp-chat` client scope attached to
   the `librechat` client — see `infra/keycloak.yaml`).
3. `OPENID_REUSE_TOKENS=true` makes LibreChat keep the Keycloak tokens on the
   user's session; `{{LIBRECHAT_OPENID_ACCESS_TOKEN}}` in `mcpServers[*].headers`
   resolves to that access token on every outbound MCP request.
4. `vmcp-chat` validates the token against the Keycloak issuer and checks
   the audience before aggregating `infra-tools` backends. Cedar policies
   in [vmcp-chat-authz.yaml](vmcp-chat-authz.yaml) filter the `tools/list`
   and `tools/call` responses by the `groups` claim, so each persona sees
   a different set of tools in LibreChat:
   - `alice` / `demo` (engineering): the full catalog (53 tools), mutations
     included
   - `bob` (finance, the "support" persona): observability only and read-only
     within it (35 tools) — Grafana, Prometheus, and OSV, but no Kubernetes and
     no OCI registry. Everything else is absent from `tools/list` and rejected
     with a 403 if called directly
   - anything else: default-deny

The `aggregation` filter in [vmcp-chat.yaml](vmcp-chat.yaml) trims Grafana to the
components this stack actually runs (the backend publishes 65 tools), but it is
about relevance, not access: both personas are offered the same catalog and only
these policies separate them. Support is scoped along two dimensions, and
neither is a maintained tool list —

```
permit(principal in THVGroup::"finance", action == Action::"call_tool", resource)
when { resource has readOnlyHint && resource.readOnlyHint == true
       && (resource.name like "grafana_*" || resource.name like "prometheus_*"
           || resource.name like "osv_*") };
```

— domain via the prefix match, capability via the annotation, so it keeps
working as backends add tools. The `has` guard makes a tool that
omits the annotation denied rather than assumed safe, which is what catches
`grafana_update_dashboard`, `grafana_create_folder`, `grafana_alerting_manage_rules`,
and the `grafana_api_request` escape hatch: none of them declare a
`readOnlyHint` either way. `addons/vmcp-infra-entra` uses the same pattern
against Entra ID app roles.

The annotations are more trustworthy than the tool names suggest, which is worth
pointing out during a demo: `grafana_alerting_manage_routing` sounds mutating but
its `operation` enum is get-only and it is correctly `readOnlyHint: true`, so
support keeps it, while `grafana_alerting_manage_rules` is full CRUD and declares
`destructiveHint: true` instead. The one tool the guard is unfair to is
`grafana_generate_deeplink`, which only builds a URL but ships no annotation, so
support loses it.

The composites are permitted by name, since
`VirtualMCPCompositeToolDefinition` has no field for tool annotations and they
would otherwise fail the guard. Support gets `mcp_server_pulse` only;
`audit_image_supply_chain` stays engineering-only, being a supply-chain workflow
over OCI tools support has no scope for.

`mcp_server_pulse` is the most interesting thing to demo here. Its first step
calls `mkp_list_resources`, which support is denied outright — yet the composite
returns populated pod data for `bob`. Composite steps route through the
aggregated routing table, while the authorization seam is only consulted on
`List`/`Lookup`, so a composite is the *sanctioned* path to a capability the tier
cannot exercise directly. Support gets a curated read of the cluster; engineering
gets the raw tools. That cuts both ways: anything a composite chains through is
effectively granted to every caller who can invoke it, so composites are a
deliberate hole in the policy and want reviewing as such.

Step 4 requires ToolHive operator **0.41.0 or newer** (the version pinned in
`versions.env`). Two converter gaps in the VirtualMCPServer rendering path used
to break it, both since fixed: `MCPOIDCConfig.caBundleRef` was mounted into the
vMCP pod but never passed to the binary
([#4918](https://github.com/stacklok/toolhive/issues/4918), operator 0.41.0),
and `authzConfig.type: configMap` was passed through unresolved
([#4919](https://github.com/stacklok/toolhive/issues/4919), operator 0.28.3).

## Pre-seeded agent

The deploy script creates an "Infra Agent" (category `it`) wired to the
`toolhive-chat` and `toolhive-docs` MCP servers. Every tool it can call except
the docs ones goes through the authenticated gateway.

Because auth is Keycloak-only, there is no local account to own the agent at
deploy time: personas are provisioned on their first OIDC login, which hasn't
happened yet. The script therefore creates a login-less ADMIN service account
(`librechat-seed@toolhive.local`, no password, unusable for sign-in), mints a
short-lived JWT for it with the instance's `JWT_SECRET`, POSTs the agent, then
grants public access via `PUT /api/permissions/agent/<id>`. The public grant is
what makes the agent visible to `demo`, `alice`, and `bob` — agents are
otherwise scoped to their author.

The grant is `agent_editor` (VIEW + EDIT), not `agent_viewer` (VIEW), so any
persona can open the agent in the builder to inspect or tweak its config rather
than only chat with it. Deleting and re-sharing stay with the owner. Scoping the
grant to one persona is not possible at deploy time, since personas don't exist
in LibreChat until their first OIDC login.

Re-running `deploy.sh` is idempotent: an agent with the same name is reused, and
only the public grant is re-applied. Note the corollary — editing
`infra-agent.json` does **not** update an agent that already exists. Delete it in
the UI first, then re-run.

The `tools` array in `infra-agent.json` is a frozen snapshot — LibreChat does
not auto-sync agent tools when the underlying MCP server's toolset changes. It
selects everything `vmcp-chat` aggregates (all 53, including the two composites)
plus the six `vmcp-docs` tools. Change the `aggregation` filter, rename an MCP
server in `values.yaml`, or add backends to `infra-tools` / `shared-tools`, and
this snapshot needs regenerating.

Note that the mutating tools are selected deliberately. An agent only ever calls
tools it has selected, so leaving them out would hide the authz split: with them
in, the same agent gives `alice` a working `mkp_apply_resource` or
`grafana_update_dashboard` and gets `bob` a 403.

To connect to a different vMCP gateway, edit the `mcpServers` and
`mcpSettings.allowedDomains` entries in `values.yaml` under `configYamlContent`.
