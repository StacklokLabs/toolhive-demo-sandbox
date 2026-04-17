# LibreChat

Deploys [LibreChat](https://www.librechat.ai/) as a chat UI connected to the demo sandbox's vMCP gateway over streamable-http.

## What it does

- Installs LibreChat via the official Helm chart (includes MongoDB)
- Connects to the `vmcp-infra` and `vmcp-docs` VirtualMCPServers for tool access
- Routes through OpenRouter for LLM inference (multi-model)
- Authenticates users via the sandbox's Keycloak realm (`toolhive-demo`); local
  email/password login and self-registration are disabled

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
- [httproute.yaml](httproute.yaml) — Gateway API route (the chart uses Ingress which we replace with HTTPRoute)

The deploy script injects the per-cluster `OPENID_ISSUER`, mirrors the Traefik
CA into the `librechat` namespace (so the Node runtime trusts the self-signed
Keycloak cert via `NODE_EXTRA_CA_CERTS`), and provisions the OIDC client secret
that matches the `librechat` client declared in `infra/keycloak.yaml`.

To connect to a different vMCP gateway, edit the `mcpServers` and `mcpSettings.allowedDomains` entries in `values.yaml` under `configYamlContent`.
