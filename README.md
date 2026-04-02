# ToolHive platform-in-a-box on Kubernetes

![Demo build](https://github.com/StacklokLabs/toolhive-demo-sandbox/actions/workflows/test-demo-build.yml/badge.svg)

This repo sets up a complete ToolHive stack locally in Kubernetes using kind.

The goal is a fully functional ToolHive platform running locally to exercise all core features and interoperability with minimal external dependencies, making it suitable for demos, development, and testing.

So far, it includes:

- A ToolHive Registry Server with a few servers filtered from the official and ToolHive registries plus K8s discovery
- The ToolHive Cloud UI connected to the registry server with a mock OIDC provider for authentication
- A Virtual MCP Server running a few basic MCP servers: fetch, osv, oci-registry, and context7
- A vMCP server with a composite tool chaining together multiple arXiv tools
- The MKP MCP server for managing the cluster, exposed directly
- A vMCP server with an embedded authorization server fronting a Google Drive MCP backend (OAuth demo)
- An MCP Optimizer server for intelligent tool calling across multiple MCP servers
- Traefik as the gateway for routing traffic into the cluster
- An observability stack to capture traces and metrics from the MCP servers
- Grafana dashboard to view MCP server metrics

## Prerequisites

- macOS, Linux, or Windows (with WSL2, see note) with Docker (Podman might work too, but untested)
- kind, kubectl, and helm
- [cloud-provider-kind](https://kubernetes-sigs.github.io/cloud-provider-kind/#/user/install/install_go)

> [!NOTE]
> Windows support is experimental and may require additional configuration. See [Windows notes](#windows-notes) section for details.

## Recommended

- k9s for viewing cluster resources

## Setup

1. Clone this repo
2. Run `./bootstrap.sh` from the repo root
3. When prompted, run `sudo cloud-provider-kind` in a separate terminal to assign a local IP to the traefik Gateway (you can also just keep this running all the time)
4. Run `thv config set-registry http://registry-<TRAEFIK-IP-WITH-HYPHENS>.traefik.me/registry` (or set a custom registry in the UI settings) to point your ToolHive instance to the local registry server
5. Access the Cloud UI, MCP servers, and Grafana via the URLs printed at the end of the bootstrap process

The bootstrap script is idempotent and can be re-run to fix any issues or reapply configurations.

## vMCP + Embedded Auth Server Demo (Google Drive)

The bootstrap optionally deploys a vMCP server with an embedded OAuth authorization server fronting a Google Drive MCP backend. This demo requires additional environment variables in `.env`:

```sh
# Google OAuth credentials (from Google Cloud Console)
GOOGLE_OAUTH_CLIENT_ID=your-google-oauth-client-id
GOOGLE_OAUTH_CLIENT_SECRET=your-google-oauth-client-secret

# GitHub PAT with read:packages scope (classic PAT required, not fine-grained)
# Needed to pull the google-drive-mcp image from a private ghcr.io repo
GHCR_PAT=your-github-classic-pat-with-read-packages
```

If these variables are not set, the bootstrap will skip this demo and print a message.

### Google OAuth setup

1. Create an OAuth 2.0 client in the [Google Cloud Console](https://console.cloud.google.com/apis/credentials)
2. Run bootstrap partway — it will pause after assigning the Traefik Gateway IP
3. Add the redirect URI to your OAuth client's **Authorized redirect URIs**:
   ```
   https://auth-<TRAEFIK-IP-WITH-HYPHENS>.traefik.me/vmcp-google-drive/oauth/callback
   ```
4. Let bootstrap finish

### Connecting with Claude Code

The demo uses a self-signed TLS certificate for the auth server endpoint. To connect with Claude Code, you need to disable TLS verification:

```sh
NODE_TLS_REJECT_UNAUTHORIZED=0 claude
```

Then add the vMCP server URL (printed at the end of bootstrap) as an MCP server in Claude Code.

> [!WARNING]
> `NODE_TLS_REJECT_UNAUTHORIZED=0` disables TLS certificate verification for all connections in that Claude Code session. Only use this for local development and demos.

## Troubleshooting

If the bootstrap fails, check the output for errors. You can also use `kubectl` or `k9s` to inspect the cluster state.

To re-run the bootstrap with more verbosity, you can set the `DEBUG` environment variable:

```sh
DEBUG=1 ./bootstrap.sh
```

## Cleanup

Run the `./cleanup.sh` script to delete the mocked OIDC provider Docker image and the cluster.

## Known issues

None at this time. Please open issues if you encounter any problems.

## Roadmap

- [x] Add an observability stack to catch traces/metrics
- [x] Add pre-configured Grafana dashboard for MCP server metrics
- [x] Harden the bootstrap script with more error checking and idempotency
- [x] Add toolhive-cloud-ui deployment
- [x] Add MCP Optimizer demo server
- [ ] Deploy registry server using the ToolHive Operator instead of manually
- [ ] Add a Keycloak instance for authentication
- [x] Add an authenticated version of the vMCP server
- [ ] Persona-specific vMCP server demos

## Example

A successful bootstrap should end with output similar to this:

```text
./bootstrap.sh

Running preflight checks...
  Checking required binaries... ✓
Creating Kind cluster... ✓
Adding Helm repositories... ✓
Updating Helm repositories... ✓
Installing cert-manager... ✓
Installing Traefik... ✓
Installing observability stack... ✓
Installing ToolHive Operator... ✓
Checking for Traefik Gateway IP... ✓ (172.19.0.3)
Installing Registry Server... ✓
Installing Cloud UI... ✓
Configuring Grafana HTTPRoute... ✓
Installing MKP MCP server... ✓
Installing vMCP demo servers... ✓
Installing vMCP Google Drive auth demo... ✓
Installing MCP Optimizer... ✓
Waiting for all pods to be ready... ✓
Writing endpoint information to demo-endpoints.json... ✓
Bootstrap complete! Access your demo services at the following URLs:
 - ToolHive Cloud UI at https://ui-172-19-0-3.traefik.me (you'll have to accept the self-signed certificate)
 - ToolHive Registry Server at http://registry-172-19-0-3.traefik.me/registry
   (run 'thv config set-registry http://registry-172-19-0-3.traefik.me/registry --allow-private-ip' to configure ToolHive to use it)
 - MKP MCP server at http://mcp-172-19-0-3.traefik.me/mkp/mcp
 - vMCP demo server at http://mcp-172-19-0-3.traefik.me/vmcp-demo/mcp
 - vMCP composite tool demo server at http://mcp-172-19-0-3.traefik.me/vmcp-research/mcp
 - MCP Optimizer at http://mcp-172-19-0-3.traefik.me/mcp-optimizer/mcp
 - vMCP Google Drive (auth demo) at http://mcp-172-19-0-3.traefik.me/vmcp-google-drive/mcp
   (auth server at https://auth-172-19-0-3.traefik.me/vmcp-google-drive)
 - Grafana at http://grafana-172-19-0-3.traefik.me
```

## Windows notes

1. On Windows, the bootstrap script must be run from a WSL2 terminal with Docker Desktop configured to use the WSL2 backend.
2. kind requires at least version 2.5.1 of WSL2 (update using `wsl --update` if needed).
3. The IP assigned by cloud-provider-kind will not be reachable from Windows host applications. For example, to access the Cloud UI, you will need to use a browser inside WSL2 (e.g., Firefox or Chromium installed in WSL2) or set up port forwarding from WSL2 to Windows.
