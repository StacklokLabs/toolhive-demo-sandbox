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
- [vmcp-chat-authz.yaml](vmcp-chat-authz.yaml) — Cedar policies gating `tools/list` + `tools/call` by the user's Keycloak `groups` claim
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
   - `alice` / `demo` (engineering): every aggregated tool
   - `bob` (finance): a narrow read-only slice (dashboard search, datasource
     listing, metric listing, vulnerability queries)
   - anything else: default-deny

Step 4 requires ToolHive operator **0.41.0 or newer** (the version pinned in
`versions.env`). Two converter gaps in the VirtualMCPServer rendering path used
to break it, both since fixed: `MCPOIDCConfig.caBundleRef` was mounted into the
vMCP pod but never passed to the binary
([#4918](https://github.com/stacklok/toolhive/issues/4918), operator 0.41.0),
and `authzConfig.type: configMap` was passed through unresolved
([#4919](https://github.com/stacklok/toolhive/issues/4919), operator 0.28.3).

## Pre-seeded agent

The deploy script creates an "Infra Agent" (category `it`) wired to the
`toolhive-chat`, `toolhive-docs`, and `toolhive-platform` MCP servers.

Because auth is Keycloak-only, there is no local account to own the agent at
deploy time: personas are provisioned on their first OIDC login, which hasn't
happened yet. The script therefore creates a login-less ADMIN service account
(`librechat-seed@toolhive.local`, no password, unusable for sign-in), mints a
short-lived JWT for it with the instance's `JWT_SECRET`, POSTs the agent, then
grants public (`agent_viewer`) access via `PUT /api/permissions/agent/<id>`.
The public grant is what makes the agent visible to `demo`, `alice`, and `bob` —
agents are otherwise scoped to their author.

Re-running `deploy.sh` is idempotent: an agent with the same name is reused, and
only the public grant is re-applied.

The `tools` array in `infra-agent.json` is a frozen snapshot of the vMCP toolset
at the time it was captured — LibreChat does not auto-sync agent tools when the
underlying MCP server's toolset changes. It currently mirrors the `vmcp-chat`
aggregation filter in [vmcp-chat.yaml](vmcp-chat.yaml) (prometheus, grafana, and
osv only — no `mkp` or `oci-registry`). If you change that filter, rename an MCP
server in `values.yaml`, or add backends to `infra-tools` or `shared-tools`,
regenerate the snapshot to keep the agent in sync.

Note that Cedar authz still applies at call time: `bob` sees the agent but its
non-finance tools will be denied by `vmcp-chat`.

To connect to a different vMCP gateway, edit the `mcpServers` and
`mcpSettings.allowedDomains` entries in `values.yaml` under `configYamlContent`.
