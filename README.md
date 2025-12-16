# ToolHive platform in a box on Kubernetes

This repo attempts to set up a complete ToolHive platform locally in Kubernetes using kind.

The goal is to have a fully functional ToolHive platform running locally to exercise all core features and interoperability with minimal external dependencies, making it suitable for demos, development, and testing.

So far, it includes:

- A ToolHive Registry Server with a few servers filtered from the main ToolHive registry and with auto-discovery enabled
- A Virtual MCP Server running a few basic MCP servers including fetch and GitHub
- ~~An authenticated version of the same vMCP server using Okta~~
- The MKP MCP server for managing the cluster, exposed directly
- ngrok tunneling for secure access to the Registry Server
- traefik gateway for local access to MCP servers and vMCP endpoints

You need:

- macOS or Linux system with Docker (Podman should work too, but untested)
- kind, kubectl, and helm
- [cloud-provider-kind](https://kubernetes-sigs.github.io/cloud-provider-kind/#/user/install/install_go)
- An ngrok account (free tier is fine) with authtoken and API key
- A GitHub personal access token with repo scope
- ~~An Okta developer account with an application created for ToolHive (contact Dan to use his)~~
- ToolHive CLI (thv) or UI with secrets created for:
  - ngrok authtoken (`thv secret set ngrok-authtoken`)
  - ngrok API key (`thv secret set ngrok-api-key`)
  - GitHub personal access token (`thv secret set github`)
  - ~~Okta client secret (`thv secret set okta-client-secret`)~~

Recommended:

- k9s for viewing cluster resources

Setup:

1. Clone this repo
2. Run `./bootstrap.sh` from the repo root
3. When prompted, run `sudo cloud-provider-kind` in a separate terminal to assign a local IP to the traefik Gateway
4. Run `thv config set-registry https://YOUR_NGROK_HOSTNAME/registry` (or set a custom registry in the UI settings) to point your ToolHive instance to the local registry server
5. Access the MKP MCP server at `http://mcp-<TRAEFIK_IP_WITH_DASHES>.traefik.me/mkp/mcp` to manage the local cluster (you can quickly test using `thv mcp list tools --server <URL>`)
6. Access the vMCP server at `http://mcp-<TRAEFIK_IP_WITH_DASHES>.traefik.me/vmcp-demo/mcp`

Known issues:

- The local IP created by `cloud-provider-kind` is different on each system and depends on your local docker networking setup.
- Manual edits are needed to set the right hostname in the HTTPRoute resources; find instances of `REPLACE_WITH_NGROK_HOSTNAME` and replace them with the hostname assigned by ngrok for the registry server (e.g. `abcd1234.ngrok.io`).
- The vMCP tends to start up before the backend MCP servers are ready, causing incomplete tool discovery. Restarting or recreating the vMCP pod resolves this.
- Error handling and prerequisite checks in the bootstrap is pretty much non-existent.

Roadmap:

- [ ] Add an observability stack (OTel Collector + Jaeger + Prometheus + Grafana) to catch traces/metrics
- [ ] Replace ngrok with sslip.io + LetsEncrypt for local tunneling or similar solution (ToolHive CLI/UI requires a secure registry endpoint)
- [ ] Default to an in-cluster Keycloak instance for authentication instead of Okta
- [ ] Persona-specific vMCP server setups
