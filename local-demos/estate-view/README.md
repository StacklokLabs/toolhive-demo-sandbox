# ToolHive Estate View Prototype

This is a read-only prototype for a ToolHive / Stacklok Enterprise management-plane idea.
It does not manage Kubernetes resources. It queries ToolHive CRDs, selected Gateway API
routes, and the demo Keycloak import, then renders a domain-specific estate report.

The goal is to answer customer-facing questions like:

- What MCP servers, remote proxies, and vMCP gateways exist?
- Which backends are aggregated by each gateway?
- Which users or groups can see each exported entry in the registry?
- Which endpoints have actual call-time authentication and authorization?
- Which tools are advertised, filtered, optimized, or exposed through composite tools?
- Where is the estate drifting from the intended access story?

## Run

From the repo root:

```sh
local-demos/estate-view/estate_view.py -n toolhive-system
```

For a compact machine-readable shape:

```sh
local-demos/estate-view/estate_view.py -n toolhive-system -o json
```

To include raw inline Cedar policies in the Markdown report:

```sh
local-demos/estate-view/estate_view.py -n toolhive-system --include-raw-policies
```

The script only runs `kubectl get` and `kubectl config current-context`. It does not
apply, patch, delete, port-forward, or exec into anything.

## What It Reads

ToolHive resources:

- `MCPServer`
- `MCPRemoteProxy`
- `MCPServerEntry`
- `VirtualMCPServer`
- `MCPGroup`
- `MCPOIDCConfig`
- `MCPExternalAuthConfig`
- `MCPToolConfig`
- `MCPTelemetryConfig`
- `MCPRegistry`
- `EmbeddingServer`
- `VirtualMCPCompositeToolDefinition`

Optional context:

- `HTTPRoute`, to connect public paths to ToolHive services
- `keycloak/keycloak-realm-import`, to build the demo persona access matrix

## Report Sections

- **Estate Summary**: counts and readiness across ToolHive CRDs.
- **Group Topology**: `MCPGroup -> backends -> vMCP front ends`.
- **Gateways**: vMCP registry claims, call-time auth, routes, backend counts, and composite tools.
- **Workloads**: MCP servers, remote proxies, group membership, images/remotes, auth, and routes.
- **Access Matrix**: demo persona visibility from `toolhive.stacklok.dev/authz-claims`.
- **Auth And Identity**: OIDC and external auth config references.
- **Tool Surface**: advertised tool definitions and aggregation/filtering hints.
- **Findings**: likely drift, demo risks, or production hardening questions.

## Current Prototype Boundary

This intentionally avoids becoming a Kubernetes management UI:

- No generic object browser.
- No manifest editing.
- No deployment workflows.
- No RBAC or cluster-admin replacement.
- No secret value reads.

It treats Kubernetes as the backing API and ToolHive as the product domain.

## Product Direction

This script is the first read model. If the idea proves useful, the next likely step is
a Headlamp plugin or small standalone UI backed by the same model:

- reuse Kubernetes auth/RBAC for read access;
- watch ToolHive CRDs with a dynamic client or informer;
- cache a graph of ToolHive resources, registry exports, identity refs, routes, and status;
- render a purpose-built estate view for platform, security, and leadership audiences.

The key product distinction is between registry visibility and call-time enforcement.
For example, a gateway can be visible only to the engineering group in the registry
while still accepting anonymous calls at the MCP endpoint. This prototype makes that
distinction explicit instead of hiding it behind generic Kubernetes YAML.
