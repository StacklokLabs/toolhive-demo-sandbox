# AWS vMCP

A VirtualMCPServer that aggregates an `MCPServerEntry` catalog entry for the [AWS MCP Server](https://docs.aws.amazon.com/aws-mcp/), with Okta SSO and AWS STS credential exchange.

## What it does

- Deploys a `MCPGroup` + `MCPServerEntry` pair — the entry is a zero-infrastructure catalog reference to `https://aws-mcp.us-east-1.api.aws/mcp` (no pod)
- Runs a `VirtualMCPServer` with an embedded OAuth 2.0 authorization server (Okta upstream) that aggregates the group
- Wires `outgoingAuth.backends.aws-mcp` to an `awsSts` `MCPExternalAuthConfig`, so the vMCP's upstream-swap middleware replaces the vMCP-issued JWT with the stored Okta token, then STS exchanges it for temporary AWS credentials and signs outgoing requests with SigV4

## How it differs from `aws-mcp`

Both addons target the same AWS MCP endpoint, but via different patterns:

| | `aws-mcp` | `aws-vmcp` |
|---|---|---|
| Frontend | `MCPRemoteProxy` (dedicated proxy pod) | `VirtualMCPServer` (aggregates a group) |
| Backend | Remote URL baked into the proxy spec | `MCPServerEntry` catalog entry in a group |
| Use case | Single remote MCP behind SSO + STS | Multiple MCPs (plus other catalog entries) behind one vMCP |

## Prerequisites

- Demo sandbox cluster running (`bootstrap.sh` completed)
- Okta OIDC Web Application with `https://<AWS_VMCP_HOSTNAME>/oauth/callback` as a redirect URI
- AWS IAM OIDC provider trusting Okta + IAM role with `AssumeRoleWithWebIdentity` trust policy

See the [`aws-mcp` addon README](../aws-mcp/README.md) for detailed Okta and AWS setup steps — the requirements are identical, except the Okta redirect URI uses `aws-vmcp-…` instead of `aws-mcp-…` as the hostname.

## Deploy

```bash
cp .env.example .env   # fill in Okta + AWS values
./deploy.sh
```

## Teardown

```bash
./teardown.sh
```

## Configuration

Edit `manifest.yaml` to customize:

- **Add more backends**: create additional `MCPServerEntry` (or `MCPServer`/`MCPRemoteProxy`) resources in the `aws-vmcp-tools` group; the vMCP discovers them automatically
- **Per-backend outgoing auth**: add entries under `outgoingAuth.backends` keyed by the backend name
- **Role mappings**: set `awsSts.roleMappings` on the `MCPExternalAuthConfig` to map Okta groups to different IAM roles
