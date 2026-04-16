# Add-ons

Optional components that extend the demo sandbox with external services, alternative UIs, or integrations requiring API keys.

## Usage

Each add-on is a self-contained directory with its own deploy/teardown scripts:

```bash
cd addons/<name>
cp .env.example .env   # fill in required secrets
./deploy.sh            # deploy into the cluster
./teardown.sh          # clean removal
```

Add-ons deploy into their own Kubernetes namespace and are independent of each other.

## Available add-ons

| Add-on | Description |
|--------|-------------|
| [librechat](librechat/) | Chat UI connected to a vMCP gateway via streamable-http |

## Creating a new add-on

Use an existing add-on as a template. The expected structure:

```
addons/<name>/
  README.md        # what it does, prerequisites, how to deploy
  .env.example     # required env vars (committed)
  .env             # actual secrets (gitignored)
  deploy.sh        # sources ../_lib.sh, deploys everything
  teardown.sh      # clean removal including namespace
  *.yaml           # Kubernetes manifests
```

Deploy scripts source the shared library for common operations:

```bash
. "$(dirname "$0")/../_lib.sh"

addon_load_env                          # load .env
addon_require_env MY_API_KEY            # fail fast if missing
addon_resolve_traefik                   # sets TRAEFIK_IP, TRAEFIK_HOSTNAME_BASE
addon_create_namespace                  # creates namespace matching directory name
addon_apply "$ADDON_DIR/manifest.yaml"  # apply with envsubst support
addon_wait_ready app=myapp              # wait for pods
addon_delete_namespace                  # teardown
```
