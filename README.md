# ToolHive platform-in-a-box on Kubernetes

![Demo build](https://github.com/StacklokLabs/toolhive-demo-sandbox/actions/workflows/test-demo-build.yml/badge.svg)

This repo sets up a complete ToolHive stack locally in Kubernetes using kind.

The goal is a fully functional ToolHive platform running locally to exercise all core features and interoperability with minimal external dependencies, making it suitable for demos, development, and testing.

So far, it includes:

- A ToolHive Registry Server with group-based access control (engineering, finance, shared tools) plus K8s auto-discovery
- Keycloak for OpenID Connect authentication with demo users and claims-based authorization
- The ToolHive Cloud UI connected to the registry server with Keycloak authentication
- Persona-specific vMCP gateways:
  - **vMCP Infra** (engineering) — Prometheus, Grafana, OSV, OCI registry, and MKP (Kubernetes)
  - **vMCP Infra (Optimized)** — same backends, but optimizer-enabled: exposes only `find_tool` and `call_tool` via semantic tool search
  - **vMCP Docs** (shared) — Context7, internal docs fetch, and a remote-proxy to hosted ToolHive docs
  - **vMCP Finance** (finance) — stubbed, awaiting real finance backends
  - **vMCP Research** (shared) — arXiv with a composite research-topic tool
- The MKP MCP server for managing the cluster, also exposed directly
- A shared text-embeddings server (HuggingFace TEI) backing the optimizer-enabled vMCPs
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
4. Accept the self-signed certificate for **both** `https://ui-<IP>.traefik.me` and `https://auth-<IP>.traefik.me` in your browser before logging in
5. Point the ToolHive CLI at the public registry:
   ```sh
   thv config set-registry http://registry-<IP>.traefik.me/registry/public --allow-private-ip
   ```
6. Access the Cloud UI, MCP servers, and Grafana via the URLs printed at the end of the bootstrap process

The bootstrap script is idempotent and can be re-run to fix any issues or reapply configurations.

## Authentication

The demo uses Keycloak for OpenID Connect authentication:

- **Admin Console**: `https://auth-<IP>.traefik.me/admin`
  - Username: `admin`
  - Password: `admin`

- **Demo Users** (realm: `toolhive-demo`, client: `toolhive-cloud-ui`):

  | User    | Password | Groups                         | Gateways they can reach                                                        |
  | ------- | -------- | ------------------------------ | ------------------------------------------------------------------------------ |
  | `demo`  | `demo`   | everyone, engineering, finance | All gateways + registry superAdmin                                             |
  | `alice` | `alice`  | everyone, engineering          | **vMCP Infra** (Prometheus/Grafana/OSV/OCI/MKP), vMCP Docs, vMCP Research, MKP |
  | `bob`   | `bob`    | everyone, finance              | **vMCP Finance** (stub), vMCP Docs, vMCP Research                              |

  All users also see shared catalog entries (Notion, Time, ToolHive docs). Alice additionally sees engineering-only catalog entries (AWS docs, Playwright, GitLab, Figma, Postman). Bob sees finance-only catalog entries (Stripe remote).

## Troubleshooting

If the bootstrap fails, check the output for errors. You can also use `kubectl` or `k9s` to inspect the cluster state.

To re-run the bootstrap with more verbosity, you can set the `DEBUG` environment variable:

```sh
DEBUG=1 ./bootstrap.sh
```

To validate all services are working:

```sh
./validate.sh
```

## Cleanup

Run the `./cleanup.sh` script to delete the cluster.

## Known issues

None at this time. Please open issues if you encounter any problems.

## Roadmap

- [x] Add an observability stack to catch traces/metrics
- [x] Add pre-configured Grafana dashboard for MCP server metrics
- [x] Harden the bootstrap script with more error checking and idempotency
- [x] Add toolhive-cloud-ui deployment
- [x] Add MCP Optimizer demo server
- [ ] Deploy registry server using the ToolHive Operator instead of manually
- [x] Add a Keycloak instance for authentication
- [x] Claims-based authorization with group-scoped registry sources
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
Installing Keycloak... ✓
Creating PostgreSQL server for ToolHive Registry Server... ✓
Creating Traefik CA ConfigMap for registry server TLS verification... ✓
Installing shared MCPTelemetryConfig resource... ✓
Installing persona MCPGroups and backends... ✓
Installing embedding server for optimizer-enabled vMCPs... ✓
Installing persona vMCP gateways... ✓
Installing Registry Server... ✓
Installing Cloud UI... ✓
Configuring Grafana HTTPRoute... ✓
Waiting for all pods to be ready... ✓
Validating registry server... ✓ (18 unique servers detected)
Writing endpoint information to demo-endpoints.json... ✓
Bootstrap complete! Access your demo services at the following URLs:
 - Keycloak Admin Console at https://auth-172-19-0-3.traefik.me/admin (admin/admin)
 - ToolHive Cloud UI at https://ui-172-19-0-3.traefik.me (NOTE: self-signed cert, expect a browser warning)
   Demo Users:
     demo  / demo   — Admin persona (registry superAdmin, sees all tools)
     alice / alice  — Engineering persona
     bob   / bob    — Finance persona
     All users see shared tools and in-cluster MCP servers.
 - ToolHive Registry Server at http://registry-172-19-0-3.traefik.me/registry/demo-registry
   (Note: registry requires authentication — use the Cloud UI or a valid Keycloak Bearer token)
 - Public Registry (no auth) at http://registry-172-19-0-3.traefik.me/registry/public for the ToolHive CLI or UI
   (run 'thv config set-registry http://registry-172-19-0-3.traefik.me/registry/public --allow-private-ip' or addin the UI settings)
 - MKP MCP server (standalone, engineering) at http://mcp-172-19-0-3.traefik.me/mkp/mcp
 - vMCP Infra gateway (alice/engineering) at http://mcp-172-19-0-3.traefik.me/vmcp-infra/mcp
 - vMCP Infra gateway (optimizer-enabled) at http://mcp-172-19-0-3.traefik.me/vmcp-infra-optimized/mcp
 - vMCP Docs gateway (shared) at http://mcp-172-19-0-3.traefik.me/vmcp-docs/mcp
 - vMCP Finance gateway (bob/finance, stub) at http://mcp-172-19-0-3.traefik.me/vmcp-finance/mcp
 - vMCP Research gateway (shared) at http://mcp-172-19-0-3.traefik.me/vmcp-research/mcp
 - Grafana at http://grafana-172-19-0-3.traefik.me
```

## Windows notes

1. On Windows, the bootstrap script must be run from a WSL2 terminal with Docker Desktop configured to use the WSL2 backend.
2. kind requires at least version 2.5.1 of WSL2 (update using `wsl --update` if needed).
3. The IP assigned by cloud-provider-kind will not be reachable from Windows host applications. For example, to access the Cloud UI, you will need to use a browser inside WSL2 (e.g., Firefox or Chromium installed in WSL2) or set up port forwarding from WSL2 to Windows.
