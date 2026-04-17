# Architecture

This repo stands up a complete ToolHive platform — operator, registry, cloud UI, Keycloak, observability, and a set of persona-scoped MCP gateways — inside a single local `kind` cluster. `./bootstrap.sh` assembles it in one shot, but the moving parts and how they relate can take a minute to hold in your head.

This doc is here to help with that. It's organized as four diagrams, each zoomed in on a different slice of the system rather than one sprawling overview:

1. **[Cluster at a glance](#1-cluster-at-a-glance)** — what's deployed where, and who talks to whom at runtime
2. **[Persona, group, and gateway model](#2-persona-group-and-gateway-model)** — how users map to MCP gateways and backends
3. **[How the registry gets its content](#3-how-the-registry-gets-its-content)** — the six sources that feed the two registries, and how group claims gate visibility
4. **[OAuth flow for the Okta-authenticated addon](#4-oauth-flow-for-the-okta-authenticated-addon)** — a sequence diagram of the full embedded-auth-server dance

For setup instructions, see [`README.md`](README.md). If you're modifying the demo, [`CLAUDE.md`](CLAUDE.md) captures the conventions and gotchas worth knowing.

## 1. Cluster at a glance

The demo is a single-node kind cluster. Traefik fronts every externally-reachable endpoint (except the Cloudflare-tunnel addons); Keycloak is the identity provider for the registry and cloud UI; the ToolHive operator reconciles the MCP workloads in `toolhive-system`; and an OTel pipeline captures traces/metrics from every MCP server.

```mermaid
graph TB
  Browser([Browser / thv CLI / MCP client])

  subgraph traefik[namespace: traefik]
    Gateway[Traefik Gateway<br/>cloud-provider-kind IP]
  end

  subgraph keycloak[namespace: keycloak]
    KC[Keycloak<br/>realm: toolhive-demo<br/>users: demo / alice / bob]
  end

  subgraph observability[namespace: observability]
    Otel[OTel Collector]
    Prom[Prometheus]
    Loki[Loki]
    Tempo[Tempo]
    Graf[Grafana<br/>+ dashboards]
  end

  subgraph toolhive[namespace: toolhive-system]
    Op[ToolHive Operator<br/>+ CRDs]
    Reg[Registry Server]
    UI[Cloud UI]
    PG[(Postgres<br/>registry-db<br/>CloudNativePG)]
    Emb[EmbeddingServer<br/>HuggingFace TEI]
    Workloads[MCPServers<br/>MCPRemoteProxies<br/>VirtualMCPServers]
  end

  Browser -->|HTTPS| Gateway
  Gateway -->|/ui| UI
  Gateway -->|/registry/*| Reg
  Gateway -->|/vmcp-*, /mkp/*| Workloads
  Gateway -->|/auth| KC
  Gateway -->|grafana-*.traefik.me| Graf

  UI -->|OIDC| KC
  Reg -->|validate Bearer| KC
  Reg --> PG
  Reg -.watch CRDs.-> Workloads
  Op -.reconcile.-> Workloads
  Op -.reconcile.-> Emb
  Workloads -->|semantic search<br/>optimizer vMCPs only| Emb
  Workloads -->|OTLP| Otel
  Otel --> Tempo
  Otel --> Prom
  Graf --> Prom
  Graf --> Loki
  Graf --> Tempo
```

**Bootstrap ordering note:** the Registry Server installs *after* every MCPGroup, MCPServer, MCPRemoteProxy, and VirtualMCPServer has reached `Ready`. Putting it earlier triggered SQLSTATE 40001 serialization storms between the K8s reconciler and the git-source sync loop and sometimes starved sources entirely. See [`CLAUDE.md`](CLAUDE.md#bootstrap-order--dont-reorder-without-care) for the longer story.

## 2. Persona, group, and gateway model

The Keycloak realm ships three users: **`demo`** (all groups, registry superAdmin), **`alice`** (engineering), and **`bob`** (finance). Backends live in MCPGroups; gateways (`VirtualMCPServer`) aggregate one group each. Multiple gateways can share a group — `vmcp-infra` and `vmcp-infra-optimized` both aggregate `infra-tools`, the difference being that the latter references an `EmbeddingServer` and exposes only `find_tool` + `call_tool`.

```mermaid
graph LR
  alice([alice<br/>everyone + engineering])
  bob([bob<br/>everyone + finance])
  demo([demo<br/>everyone + engineering + finance])

  subgraph InfraGateways[engineering-gated]
    vmcpInfra[vmcp-infra]
    vmcpOpt[vmcp-infra-optimized<br/>+ EmbeddingServer]
  end

  subgraph SharedGateways[everyone-gated]
    vmcpDocs[vmcp-docs]
    vmcpResearch[vmcp-research]
  end

  subgraph FinGateways[finance-gated]
    vmcpFin[vmcp-finance]
  end

  InfraTools[(infra-tools<br/>prometheus · grafana<br/>osv · oci-registry · mkp)]
  SharedTools[(shared-tools<br/>fetch · context7<br/>toolhive-docs proxy)]
  ResearchTools[(research-tools<br/>arxiv)]
  FinTools[(finance-tools<br/>finance-fetch)]

  alice --> vmcpInfra
  alice --> vmcpOpt
  alice --> vmcpDocs
  alice --> vmcpResearch
  bob --> vmcpDocs
  bob --> vmcpResearch
  bob --> vmcpFin
  demo -.all.-> vmcpInfra
  demo -.all.-> vmcpDocs
  demo -.all.-> vmcpFin
  demo -.all.-> vmcpResearch

  vmcpInfra --> InfraTools
  vmcpOpt --> InfraTools
  vmcpDocs --> SharedTools
  vmcpResearch --> ResearchTools
  vmcpFin --> FinTools
```

Gating happens at two layers:

- **Registry visibility** — the `toolhive.stacklok.dev/authz-claims` annotation on a vMCP (or MCPServer / MCPRemoteProxy) decides which authenticated users can *see* it in the registry.
- **Call-time auth** — most gateways are `incomingAuth: anonymous`. Authenticated gateways like `vmcp-infra-okta` (addon) plug in an embedded OAuth authorization server and `incomingAuth: oidc`.

## 3. How the registry gets its content

This is the trickiest mental model in the demo. The Registry Server pulls from **six configured sources**, combines them into **two named registries**, and applies per-source claims to decide who sees what. There's also a single standalone route (`/mkp/mcp`) that lives outside the registry entirely — available to anyone who knows the URL.

```mermaid
graph TB
  subgraph external[External sources]
    gitCat[Git: stacklok/toolhive-catalog<br/>pkg/catalog/.../registry-upstream.json]
    mcpApi[API: registry.modelcontextprotocol.io]
  end

  subgraph inCluster[Live cluster state]
    k8sRes[K8s resources with<br/>registry-export: true]
  end

  subgraph sources["Registry Server <i>sources</i> (6)"]
    direction TB
    s1["toolhive-shared<br/>filter: notion, time, toolhive-doc<br/>claims: everyone"]
    s2["toolhive-engineering<br/>filter: aws-doc, filesystem, playwright<br/>claims: engineering"]
    s3["toolhive-finance<br/>filter: stripe-remote<br/>claims: finance"]
    s4["toolhive-public<br/>filter: union of the above<br/>no claims"]
    s5["official-engineering<br/>filter: figma, gitlab, postman<br/>claims: engineering"]
    s6["k8s<br/>discovers MCPServer / MCPRemoteProxy /<br/>VirtualMCPServer with registry-export=true<br/>per-entry claims from authz-claims annotation"]
  end

  subgraph registries["Registries exposed by the server"]
    demoReg["<b>demo-registry</b><br/>auth: Bearer token<br/>publicPaths: none"]
    pubReg["<b>public</b><br/>no auth<br/>for thv CLI / CI"]
  end

  gitCat --> s1
  gitCat --> s2
  gitCat --> s3
  gitCat --> s4
  mcpApi --> s5
  k8sRes --> s6

  s1 --> demoReg
  s2 --> demoReg
  s3 --> demoReg
  s5 --> demoReg
  s6 --> demoReg
  s6 --> pubReg
  s4 --> pubReg

  alice([alice]) -->|Bearer| demoReg
  bob([bob]) -->|Bearer| demoReg
  cli([thv CLI / anonymous]) -.-> pubReg
```

**Per-entry filtering on the K8s source** is why `alice` and `bob` see different things in the same `demo-registry`: every MCPServer / MCPRemoteProxy / VirtualMCPServer carries an `authz-claims` annotation that the server matches against the user's group claim from Keycloak. `demo` is a `superAdmin` in the registry's authz config so they see everything regardless. The `public` registry reuses the same `k8s` source but is queried unauthenticated, so claim-based filtering doesn't apply there — every `registry-export=true` K8s resource is visible.

**Notable non-source:** the standalone `mkp` workload has its own HTTPRoute at `/mkp/mcp` and is *also* in `infra-tools`, so it shows up twice — once as a direct standalone entry, once inside `vmcp-infra`'s aggregated tool list.

## 4. OAuth flow for the Okta-authenticated addon

The `vmcp-infra-okta` addon is the most interesting auth topology in the repo. The vMCP runs its own embedded OAuth authorization server (thanks to the operator) and delegates the actual login to Okta. MCP clients go through a normal RFC 9728 discovery → OAuth2 authorization code flow, then present a JWT the vMCP itself signed.

```mermaid
sequenceDiagram
  autonumber
  participant C as MCP Client
  participant CF as Cloudflare Tunnel
  participant V as vmcp-infra-okta<br/>(embedded auth server)
  participant O as Okta
  participant B as Backend<br/>(prometheus, grafana, ...)

  C->>CF: POST /mcp (no token)
  CF->>V: forward
  V-->>C: 401 WWW-Authenticate:<br/>Bearer resource_metadata=...

  C->>V: GET /.well-known/oauth-protected-resource
  V-->>C: authorization_server=https://<tunnel>/

  C->>V: GET /.well-known/oauth-authorization-server
  V-->>C: authorize / token endpoints<br/>(on the embedded server)

  C->>V: GET /authorize?...
  V->>O: 302 to Okta /authorize
  O-->>C: login UI
  C->>O: credentials
  O->>V: 302 to /oauth/callback?code=...
  V->>O: POST /token (exchange Okta code)
  O-->>V: Okta id_token + access_token
  V-->>C: 302 to client redirect_uri with embedded-server code

  C->>V: POST /token (embedded-server exchange)
  V-->>C: access_token (JWT signed by V)

  C->>V: POST /mcp (Bearer vMCP JWT)
  V->>V: validate JWT<br/>(issuer = tunnel URL)
  V->>B: proxy tool call (outgoing: anonymous)
  B-->>V: result
  V-->>C: result
```

The backend MCPServers in `infra-tools` don't know anything about Okta — the vMCP handles all the token validation and forwards calls anonymously. Adding per-backend identity (token exchange to a downstream IdP) is what `MCPExternalAuthConfig` is for, and it slots in at step 16 without affecting anything else in this diagram.

## Where things live

- **[bootstrap.sh](bootstrap.sh)** — apply order, env-var detection, endpoint JSON
- **[demo-manifests/](demo-manifests/)** — MCPGroups, MCPServers, VirtualMCPServers, EmbeddingServer, registry helm values
- **[infra/](infra/)** — cluster-level infra (cert-manager certs, traefik values, keycloak realm import, observability stack, registry Postgres)
- **[addons/](addons/)** — opt-in features (`librechat`, `cloud-ui-openrouter`, `vmcp-infra-okta`). Each self-contained with `deploy.sh` / `teardown.sh` / `.env.example`
- **[local-demos/](local-demos/)** — ad-hoc one-offs not wired into `bootstrap.sh`
