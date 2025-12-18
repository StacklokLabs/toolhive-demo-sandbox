# ToolHive platform-in-a-box on Kubernetes

This repo sets up a complete ToolHive stack locally in Kubernetes using kind.

The goal is a fully functional ToolHive platform running locally to exercise all core features and interoperability with minimal external dependencies, making it suitable for demos, development, and testing.

So far, it includes:

- A ToolHive Registry Server with a few servers filtered from the main ToolHive registry and with auto-discovery enabled
- A Virtual MCP Server running a few basic MCP servers: fetch, osv, oci-registry, and context7
- ~~An authenticated version of the same vMCP server using Okta~~
- The MKP MCP server for managing the cluster, exposed directly
- Traefik as the gateway for routing traffic into the cluster
- An observability stack to capture traces and metrics from the MCP servers
- Grafana dashboard to view MCP server metrics

## Prerequisites

- macOS or Linux system with Docker (Podman should work too, but untested)
- kind, kubectl, and helm
- [cloud-provider-kind](https://kubernetes-sigs.github.io/cloud-provider-kind/#/user/install/install_go)
- A GitHub personal access token with repo scope
- ~~An Okta developer account with an application created for ToolHive (contact Dan to use his)~~

## Recommended

- k9s for viewing cluster resources

## Setup

1. Clone this repo
2. Run `./bootstrap.sh` from the repo root
3. When prompted, run `sudo cloud-provider-kind` in a separate terminal to assign a local IP to the traefik Gateway
4. Run `thv config set-registry http://registry-<TRAEFIK_IP>.traefik.me/registry` (or set a custom registry in the UI settings) to point your ToolHive instance to the local registry server
5. Access the MCP servers and Grafana via the URLs printed at the end of the bootstrap process

The bootstrap script is idempotent and can be re-run to fix any issues or reapply configurations.

## Cleanup

Run the `./cleanup.sh` script to delete the cluster (or just run `kind delete cluster --name toolhive-demo-in-a-box`).

## Known issues

None at this time. Please open issues if you encounter any problems.

## Roadmap

- [x] Add an observability stack to catch traces/metrics
- [x] Add pre-configured Grafana dashboard for MCP server metrics
- [x] Harden the bootstrap script with more error checking and idempotency
- [ ] Add toolhive-cloud-ui deployment
- [ ] Deploy registry server using the ToolHive Operator instead of manually
- [ ] Add an authenticated version of the vMCP server using Okta
- [ ] Persona-specific vMCP server demos
- [ ] Default to an in-cluster Keycloak instance for authentication instead of Okta
- [x] Remove ngrok (ToolHive supports a non-https registry server with `--allow-private-ip` flag)

## Example

A successful bootstrap should end with output similar to this:

```text
./bootstrap.sh

Running preflight checks...
  Checking required binaries... ✓
Creating Kind cluster... ✓
Adding Helm repositories... ✓
Updating Helm repositories... ✓
Installing Traefik... ✓
Installing cert-manager... ✓
Installing observability stack... ✓
Installing ToolHive Operator... ✓
Now, run 'sudo cloud-provider-kind' in another terminal to assign an IP to the traefik gateway. Press Enter to continue once running...
Installing Registry Server... ✓
Configuring Grafana HTTPRoute... ✓
Installing MKP MCP server... ✓
Installing vMCP demo servers... ✓
Bootstrap complete! Access your demo services at the following URLs:
 - ToolHive Registry Server at http://registry-172-19-0-3.traefik.me/registry
   (run 'thv config set-registry http://registry-172-19-0-3.traefik.me/registry --allow-private-ip' to configure ToolHive to use it)
 - MKP MCP server at http://mcp-172-19-0-3.traefik.me/mkp/mcp
 - vMCP demo server at http://mcp-172-19-0-3.traefik.me/vmcp-demo/mcp
 - Grafana at http://grafana-172-19-0-3.traefik.me
```
