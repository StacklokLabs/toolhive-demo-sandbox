# LibreChat

Deploys [LibreChat](https://www.librechat.ai/) as a chat UI connected to the demo sandbox's vMCP gateway over streamable-http.

## What it does

- Installs LibreChat via the official Helm chart (includes MongoDB)
- Connects to the `vmcp-infra` and `vmcp-docs` VirtualMCPServers for tool access
- Routes through OpenRouter for LLM inference (multi-model)
- Seeds a demo user for immediate login

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

To connect to a different vMCP gateway, edit the `mcpServers` and `mcpSettings.allowedDomains` entries in `values.yaml` under `configYamlContent`.
