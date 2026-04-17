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
- [httproute.yaml](httproute.yaml) — Gateway API route (the chart uses Ingress which we replace with HTTPRoute)

The deploy script injects the per-cluster `OPENID_ISSUER`, mirrors the Traefik
CA into the `librechat` namespace (so the Node runtime trusts the self-signed
Keycloak cert via `NODE_EXTRA_CA_CERTS`), and provisions the OIDC client secret
that matches the `librechat` client declared in `infra/keycloak.yaml`.

## How authentication flows

1. User hits `https://chat-<traefik-ip>.traefik.me`; LibreChat auto-redirects
   to Keycloak (`OPENID_AUTO_REDIRECT=true`).
2. After Keycloak auth, LibreChat receives an access token whose `aud` claim
   includes `toolhive-vmcp-chat` (via the `mcp-chat` client scope attached to
   the `librechat` client — see `infra/keycloak.yaml`).
3. `OPENID_REUSE_TOKENS=true` makes LibreChat keep the Keycloak tokens on the
   user's session; `{{LIBRECHAT_OPENID_ACCESS_TOKEN}}` in `mcpServers[*].headers`
   resolves to that access token on every outbound MCP request.
4. `vmcp-chat` validates the token against the Keycloak issuer and checks
   the audience before aggregating `infra-tools` backends. Cedar authz
   policies (future work) filter tools by the `groups` claim.

### Known issue — blocked on operator fix

Step 4 currently fails on ToolHive operator **v0.21.0** because the operator
mounts `MCPOIDCConfig.caBundleRef` into the vMCP pod but never tells the vmcp
binary where the CA is — so OIDC discovery against the self-signed `traefik.me`
cert errors with `x509: certificate signed by unknown authority`. Tracked in
[stacklok/toolhive#4918](https://github.com/stacklok/toolhive/issues/4918).

Once that ships in the operator chart, no changes should be needed here — the
manifest in [vmcp-chat.yaml](vmcp-chat.yaml) already configures `caBundleRef`
correctly.

To connect to a different vMCP gateway, edit the `mcpServers` and
`mcpSettings.allowedDomains` entries in `values.yaml` under `configYamlContent`.
