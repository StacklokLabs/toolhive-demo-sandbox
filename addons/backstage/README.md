# Backstage

Deploys a custom [Backstage](https://backstage.io/) developer portal wired into the demo sandbox, surfacing ToolHive MCP servers as catalog entities and providing software templates for deploying new ones.

## What it does

- Registers all in-cluster `MCPServer` resources as Backstage catalog entities (auto-synced every 30 s)
- Shows live status (running / stopped / error) and spec details for each server
- Provides a **Registry Browser** tab backed by the sandbox's public ToolHive registry
- Ships four software templates under `/create`:
  - **Deploy MCP Server** — generic MCPServer via ToolHive operator
  - **Deploy MCP Fetch** — pre-configured fetch MCP server
  - **Deploy GitHub MCP** — GitHub MCP integration (requires `GITHUB_TOKEN`)
  - **Deploy from Registry** — pick a server from the registry and deploy it
- Routes through Traefik at `http://backstage-<ip>.sslip.io`

## Prerequisites

- Demo sandbox cluster running (`./bootstrap.sh` completed)
- Docker (to build the image)
- Yarn (`npm install -g yarn` or via your package manager)
- Node.js 18+

> **Note:** This addon requires building a Docker image locally before deploying.
> Unlike other addons, there is no pre-published image — the image includes
> custom Backstage plugins specific to this demo.

## Build the image

Run these commands from the `addons/backstage/` directory:

```bash
# 1. Install dependencies and build the JS bundle + backend
yarn install
yarn build:backend

# 2. Build the Docker image
docker build -t backstage-toolhive-demo:latest .
```

The build takes **5–15 minutes** on first run (native modules compile from source).
Subsequent builds reuse Docker layer cache and are much faster (~1–2 min).

### Loading into kind

Because the demo cluster uses kind, Docker Hub is not reachable for locally-tagged
images. Load the image directly into the cluster:

```bash
kind load docker-image backstage-toolhive-demo:latest --name toolhive-demo-sandbox
```

## Deploy

```bash
cp .env.example .env   # fill in GITHUB_TOKEN if you want the GitHub template to work
./deploy.sh
```

The script resolves the Traefik IP, creates the `backstage` namespace, applies RBAC,
renders the ConfigMap, deploys the workload, and prints the URL when ready.

## Teardown

```bash
./teardown.sh
```

Removes the HTTPRoute, Deployment, Service, ConfigMap, RBAC, and namespace.

## Configuration

| File | Purpose |
|------|---------|
| `manifests/configmap.yaml` | Production `app-config.yaml` (envsubst'd by `deploy.sh`) — registry URL, Kubernetes cluster ref, catalog locations |
| `manifests/deployment.yaml` | Deployment spec — image name, resource limits, config mount |
| `manifests/httproute.yaml` | Gateway API route via Traefik |
| `manifests/clusterrole.yaml` | RBAC — full CRUD on `MCPServers`, read-only on other ToolHive CRDs |
| `templates/` | Backstage software templates (YAML) |
| `plugins/toolhive/` | Frontend plugin — MCP server list, detail, and registry pages |
| `plugins/toolhive-backend/` | Backend plugin — K8s API proxy for MCPServer CRUD |
| `preload.js` | Node.js `--require` preload that replaces `node-fetch` 2.x with native fetch to avoid `ERR_STREAM_PREMATURE_CLOSE` on Node 22 |

### Custom image tag

Set `BACKSTAGE_IMAGE` in `.env` to override the default `backstage-toolhive-demo:latest`:

```bash
BACKSTAGE_IMAGE=my-registry/backstage-toolhive-demo:v1.2.3
```

### GitHub integration

Set `GITHUB_TOKEN` in `.env` to a personal access token with `repo` scope. This
enables the GitHub MCP template and populates the Backstage GitHub integration.

## Re-deploying after code changes

After editing plugin source or templates, the `Makefile` provides a shortcut:

```bash
make reload   # build + image + load + kubectl rollout restart
```

Or run the steps individually:

```bash
make build    # yarn install && yarn build:backend
make image    # docker build
make load     # kind load docker-image into cluster
kubectl rollout restart deployment/backstage -n backstage
```

After editing only Kubernetes manifests (ConfigMap, RBAC, HTTPRoute):

```bash
./deploy.sh   # idempotent — re-applies manifests without touching the image
```

## Architecture notes

- **Auth**: guest provider with `dangerouslyAllowOutsideDevelopment: true` — no login required, suitable for demo use only.
- **Database**: SQLite in-memory; catalog state is rebuilt from file locations on each restart.
- **Internal fetch**: `preload.js` (loaded via `NODE_OPTIONS=--require`) intercepts `require('node-fetch')` and substitutes Node.js 22's built-in `fetch`. This is required because `cross-fetch` (used internally by `@backstage/catalog-client` and the scaffolder) pulls in `node-fetch` 2.x, which has a stream incompatibility with Node 22's `autoDestroy` behaviour causing `ERR_STREAM_PREMATURE_CLOSE` on every template load.
- **RBAC**: The `backstage-toolhive-manager` ClusterRole grants full CRUD on `MCPServers` (so templates can deploy servers) and read-only access to all other ToolHive CRDs (for the catalog sync and UI).
