# GitHub MCP Server (Local)

Deploys the open source [GitHub MCP Server](https://github.com/github/github-mcp-server) as a ToolHive-managed MCPServer using a Personal Access Token, accessible via the shared MCP gateway endpoint.

## What it does

- Deploys the GitHub MCP server (read-only mode) into `toolhive-system`
- Exposes it at `/github` on the existing `mcp-<ip>.traefik.me` endpoint
- Exports to the ToolHive registry for discovery
- Includes telemetry and audit logging via the shared OpenTelemetry config

## Prerequisites

- Demo sandbox cluster running (`bootstrap.sh` completed)
- A [GitHub Personal Access Token](https://github.com/settings/tokens) with `repo` and `read:org` scopes

## Deploy

If the `gh` CLI is installed and authenticated, the deploy script will use your existing token automatically:

```bash
./deploy.sh
```

Otherwise, provide a PAT via `.env`:

```bash
cp .env.example .env   # then fill in your GitHub PAT
./deploy.sh
```

## Teardown

```bash
./teardown.sh
```

## Configuration

- [mcpserver.yaml](mcpserver.yaml) — MCPServer resource, Secret, and HTTPRoute
- Set `GITHUB_READ_ONLY` to `0` in the manifest to enable write operations
