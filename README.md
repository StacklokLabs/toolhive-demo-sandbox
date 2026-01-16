# ToolHive platform-in-a-box on Kubernetes

![Demo build](https://github.com/StacklokLabs/toolhive-demo-sandbox/actions/workflows/test-demo-build.yml/badge.svg)

This repo sets up a complete ToolHive stack locally in Kubernetes using kind.

The goal is a fully functional ToolHive platform running locally to exercise all core features and interoperability with minimal external dependencies, making it suitable for demos, development, and testing.

So far, it includes:

- A ToolHive Registry Server with a few servers filtered from the main ToolHive registry and with auto-discovery enabled
- The ToolHive Cloud UI connected to the registry server with a mock OIDC provider for authentication
- A Virtual MCP Server running a few basic MCP servers: fetch, osv, oci-registry, and context7
- The MKP MCP server for managing the cluster, exposed directly
- An MCP Optimizer server for intelligent tool calling across multiple MCP servers
- Traefik as the gateway for routing traffic into the cluster
- An observability stack to capture traces and metrics from the MCP servers
- Grafana dashboard to view MCP server metrics

## Prerequisites

- macOS or Linux system with Docker (Podman might work too, but untested)
- kind, kubectl, and helm
- [cloud-provider-kind](https://kubernetes-sigs.github.io/cloud-provider-kind/#/user/install/install_go)

## Recommended

- k9s for viewing cluster resources

## Setup

1. Clone this repo
2. Run `./bootstrap.sh` from the repo root
3. When prompted, run `sudo cloud-provider-kind` in a separate terminal to assign a local IP to the traefik Gateway (you can also just keep this running all the time)
4. Run `thv config set-registry http://registry-<TRAEFIK-IP-WITH-HYPHENS>.traefik.me/registry` (or set a custom registry in the UI settings) to point your ToolHive instance to the local registry server
5. Access the Cloud UI, MCP servers, and Grafana via the URLs printed at the end of the bootstrap process

The bootstrap script is idempotent and can be re-run to fix any issues or reapply configurations.

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
- [ ] Add an authenticated version of the vMCP server
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
Installing MCP Optimizer... ✓
Waiting for all pods to be ready... ✓
Writing endpoint information to demo-endpoints.json... ✓
Bootstrap complete! Access your demo services at the following URLs:
 - ToolHive Cloud UI at https://ui-172-19-0-3.traefik.me (you'll have to accept the self-signed certificate)
 - ToolHive Registry Server at http://registry-172-19-0-3.traefik.me/registry
   (run 'thv config set-registry http://registry-172-19-0-3.traefik.me/registry --allow-private-ip' to configure ToolHive to use it)
 - MKP MCP server at http://mcp-172-19-0-3.traefik.me/mkp/mcp
 - vMCP demo server at http://mcp-172-19-0-3.traefik.me/vmcp-demo/mcp
 - MCP Optimizer at http://mcp-172-19-0-3.traefik.me/mcp-optimizer/mcp
 - Grafana at http://grafana-172-19-0-3.traefik.me
```
