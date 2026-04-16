# vmcp-infra-okta

Authenticated mirror of the infra vMCP gateway. Same Prometheus / Grafana / OSV / OCI / MKP backends as `vmcp-infra`, but fronted by ToolHive's embedded OAuth authorization server, which delegates authentication to Okta and exposes the gateway externally over HTTPS via a Cloudflare tunnel.

## What it does

- Deploys a `VirtualMCPServer` named `vmcp-infra-okta` that aggregates the `infra-tools` group
- Enables the embedded auth server with Okta as the upstream OIDC identity provider
- Publishes the server at `https://<your-domain>/mcp` via a Cloudflare tunnel
- Shows up in the demo registry with `authz-claims: engineering`

Sits **alongside** the existing `vmcp-infra` — the unauthenticated Traefik-routed copy — for a clean compare-and-contrast.

## Prerequisites

- Demo sandbox cluster running (`bootstrap.sh` completed)
- An Okta authorization server + application configured (see below)
- A Cloudflare tunnel configured (see below) and a domain under your control

## Okta setup

In the [Okta admin console](https://integrator-9462356-admin.okta.com/):

1. **Authorization Server** — Security → API → Authorization Servers → Add:
   - **Name**: e.g. `vMCP Infra Auth`
   - **Audience**: `https://<your-subdomain>.stacklok-demo.com/mcp` (must match the Cloudflare tunnel hostname)

2. **Application** — Applications → Create App Integration:
   - **Sign-in method**: OIDC
   - **Application type**: Web Application
   - **Grant type**: Authorization Code
   - **Sign-in redirect URI**: `https://<your-subdomain>.stacklok-demo.com/oauth/callback`
   - **Assignments**: your demo users/groups

3. Capture:
   - **Client ID** and **Client Secret** from the application
   - **Issuer URL** from the authorization server (e.g. `https://integrator-XXXXXXX.okta.com/oauth2/ausXXXXXXXX`)

## Cloudflare tunnel setup

In the [Cloudflare dashboard](https://one.dash.cloudflare.com/), create a tunnel:

- **Subdomain**: e.g. `<name>-vmcp-infra-okta`
- **Domain**: `stacklok-demo.com` (or any domain you control)
- **Path**: (empty — all paths must route, including `/oauth/callback`)
- **Service Type**: `HTTP`
- **Service URL**: `vmcp-vmcp-infra-okta.toolhive-system.svc.cluster.local:4483`

Copy the tunnel token.

## Deploy

```bash
cp .env.example .env   # then fill in the Okta + tunnel values
./deploy.sh
```

## Teardown

```bash
./teardown.sh
```

## Verify

```bash
kubectl get virtualmcpserver vmcp-infra-okta -n toolhive-system
kubectl get pods -n vmcp-infra-okta
```

Then test with the ToolHive CLI:

```bash
thv run --name vmcp-infra-okta --transport streamable-http https://<your-subdomain>.stacklok-demo.com/mcp
```

You'll be redirected to Okta; after authenticating, the vMCP is available.

## Configuration

- [vmcp.yaml](vmcp.yaml) — VirtualMCPServer: auth config, registry annotations, aggregation filters
- [cloudflared.yaml](cloudflared.yaml) — tunnel Deployment (namespace `vmcp-infra-okta`)
