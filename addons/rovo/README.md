# Atlassian Rovo MCP Addon

Proxies the [Atlassian remote MCP server](https://support.atlassian.com/atlassian-rovo-mcp-server/) through ToolHive with OAuth 2.0 authentication via an embedded auth server.

Uses **RFC 7591 Dynamic Client Registration** against the Atlassian MCP server's OAuth metadata, so no pre-provisioned Atlassian OAuth app is required — ToolHive registers itself at runtime.

## What it does

Deploys an `MCPRemoteProxy` that fronts `https://mcp.atlassian.com/v1/mcp`. MCP clients authenticate with the embedded auth server (which issues ToolHive JWTs), and the proxy swaps those JWTs for the stored Atlassian access tokens before forwarding requests upstream.

```
MCP Client → EAS (DCR + Atlassian OAuth login) → ToolHive JWT
           → MCPRemoteProxy validates JWT
           → Upstream swap: JWT → Atlassian token
           → https://mcp.atlassian.com/v1/mcp
```

The DCR discovery document at `https://mcp.atlassian.com/.well-known/oauth-authorization-server` provides the registration, authorization, and token endpoints at runtime.

## Prerequisites

- A Rovo-licensed Atlassian Cloud site (the MCP server requires Rovo to be enabled).
- Demo cluster running with Traefik exposed (the bootstrap script handles this).
- Auth server callback domain allowlisted at `https://admin.atlassian.com/` -> "Rovo" -> "Rovo MCP Server" (e.g. `https://rovo-mcp-172-19-0-4.traefik.me/**`).

That's it — no developer console app, no client ID, no client secret.

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

- The proxy is exported to the registry without `authz-claims`, so it is visible to all authenticated users. Add an `authz-claims` annotation to restrict by group.
- Access is bounded by the authenticated user's existing Atlassian permissions — the MCP server enforces this upstream.
- The dynamically-registered client lives only as long as the EAS instance; tearing down and redeploying the addon re-registers a fresh client on the next OAuth flow.
