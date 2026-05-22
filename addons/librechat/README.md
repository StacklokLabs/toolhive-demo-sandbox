# LibreChat

Deploys [LibreChat](https://www.librechat.ai/) as a chat UI connected to the demo sandbox's vMCP gateway over streamable-http.

## What it does

- Installs LibreChat via the official Helm chart (includes MongoDB)
- Connects to the `vmcp-infra` and `vmcp-docs` VirtualMCPServers for tool access
- Routes through OpenRouter for LLM inference (multi-model)
- Seeds a demo user for immediate login
- Pre-seeds an "Infra Agent" wired to both vMCPs so the demo has a ready-to-chat agent on first launch

## Prerequisites

- Demo sandbox cluster running (`bootstrap.sh` completed)
- An [OpenRouter](https://openrouter.ai/) API key

## Deploy

```bash
cp .env.example .env   # then fill in your OpenRouter key
./deploy.sh
```

The script prints the URL and login credentials when done.

## Teardown

```bash
./teardown.sh
```

Removes all resources including the Helm release, namespace, and persistent volumes.

## Configuration

- [values.yaml](values.yaml) — Helm values (LibreChat config, models, MCP endpoints, allowed domains)
- [httproute.yaml](httproute.yaml) — Gateway API route (the chart uses Ingress which we replace with HTTPRoute)
- [infra-agent.json](infra-agent.json) — payload for the pre-seeded "Infra Agent" (POSTed to `/api/agents` on deploy if not already present)

To connect to a different vMCP gateway, edit the `mcpServers` and `mcpSettings.allowedDomains` entries in `values.yaml` under `configYamlContent`.

### Pre-seeded agent

The deploy script creates an "Infra Agent" (owned by the `demo` user, category `it`) via the LibreChat REST API. The `tools` array in `infra-agent.json` is a frozen snapshot of the vMCP toolset at the time it was captured — LibreChat does not auto-sync agent tools when the underlying MCP server's toolset changes. If you add or remove backends in `infra-tools` or `shared-tools`, regenerate the snapshot and update `infra-agent.json` to keep the agent in sync.
