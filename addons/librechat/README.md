# LibreChat

Deploys [LibreChat](https://www.librechat.ai/) as a chat UI connected to the demo sandbox's vMCP gateway over streamable-http.

## What it does

- Deploys LibreChat (v0.8.4) and MongoDB into a `librechat` namespace
- Connects to the `vmcp-demo` VirtualMCPServer for tool access
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

Removes all resources including the namespace and persistent volumes.

## Configuration

- [librechat.yaml](librechat.yaml) — LibreChat config (models, MCP endpoints, allowed domains)
- [librechat-app.yaml](librechat-app.yaml) — Deployment, Service, HTTPRoute
- [mongodb.yaml](mongodb.yaml) — MongoDB StatefulSet

To connect to a different vMCP gateway, edit the `mcpServers` and `mcpSettings.allowedDomains` entries in `librechat.yaml`.
