# Atlassian Rovo MCP Addon

Proxies the [Atlassian remote MCP server](https://support.atlassian.com/atlassian-rovo-mcp-server/) through ToolHive with OAuth 2.0 authentication via an embedded auth server.

## What it does

Deploys an `MCPRemoteProxy` that fronts `https://mcp.atlassian.com/v1/mcp`. MCP clients authenticate with the embedded auth server (which issues ToolHive JWTs), and the proxy swaps those JWTs for the stored Atlassian OAuth tokens before forwarding requests upstream.

```
MCP Client → EAS (Atlassian OAuth login) → ToolHive JWT
           → MCPRemoteProxy validates JWT
           → Upstream swap: JWT → Atlassian token
           → https://mcp.atlassian.com/v1/mcp
```

## Prerequisites

1. Create an Atlassian OAuth 2.0 (3LO) app at <https://developer.atlassian.com/console/myapps/>.
2. Under **Authorization**, add the callback URL (replace `<TRAEFIK_IP>` with your cluster's Traefik IP):
   ```
   https://rovo-mcp-<TRAEFIK_IP-dashed>.traefik.me/oauth/callback
   ```
   Run `kubectl get gateway -n traefik traefik-gateway -o jsonpath='{.status.addresses[0].value}'` to find the IP.
3. Under **Permissions**, add the scopes your demo needs. Typical set:
   - `offline_access`
   - `read:jira-work`, `write:jira-work`, `read:jira-user`
   - `read:confluence-content.all`, `write:confluence-content`
4. Copy the **Client ID** and **Client Secret** from the app's Settings page.

## Setup

```bash
cp addons/rovo/.env.example addons/rovo/.env
# Fill in ATLASSIAN_CLIENT_ID and ATLASSIAN_CLIENT_SECRET
```

## Deploy / teardown

```bash
# Deploy
bash addons/rovo/deploy.sh

# Remove
bash addons/rovo/teardown.sh
```

## Connecting with Claude Code

The proxy is served over HTTPS via Traefik's traefik.me wildcard certificate. Node.js does not trust this CA by default, so launch Claude with TLS verification disabled:

```bash
NODE_TLS_REJECT_UNAUTHORIZED=0 claude
```

## Notes

- Scopes in `mcpremoteproxy.yaml` must be a subset of what is configured in the Atlassian developer console. Adjust and re-apply if you add or remove scopes.
- The proxy is exported to the registry without `authz-claims`, so it is visible to all authenticated users. Add an `authz-claims` annotation to restrict by group.
- Access is bounded by the authenticated user's existing Atlassian permissions — the MCP server enforces this upstream.
