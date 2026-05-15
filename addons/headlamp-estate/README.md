# Headlamp Estate Addon

Deploys a cluster-local Headlamp instance with a local ToolHive Estate plugin.

This is a prototype management-plane view, not a general Kubernetes dashboard:

- the service account is bound to read-only RBAC;
- no plugin is published to a catalog or plugin manager;
- plugin assets are built locally and mounted into Headlamp from a ConfigMap.
- estate data is served through a narrow `/estate-api` sidecar endpoint, so
  browser users do not need a Kubernetes login token.

The stock Headlamp sidebar remains available in this prototype so routing and
cluster selection stay close to upstream behavior. The read-only ToolHive estate
view is exposed as a no-auth `ToolHive Estate` page.

## What It Shows

- ToolHive resource inventory
- `VirtualMCPServer -> MCPGroup -> backend` topology
- registry visibility from `toolhive.stacklok.dev/authz-claims`
- call-time auth from `incomingAuth`, `oidcConfigRef`, `authServerRef`, and Cedar config
- advertised tool surface
- findings for anonymous exported endpoints, state-changing tools, demo-only OIDC settings, and public-registry exposure

## Deploy

From this directory:

```sh
./deploy.sh
```

The addon prints an `estate-<IP>.sslip.io/toolhive-estate` URL when ready.

## Teardown

```sh
./teardown.sh
```

## Notes

The plugin reads the demo Keycloak realm import ConfigMap to build the persona access
matrix. In a real enterprise deployment, that source would be replaced with live IdP
or directory integration.

The important distinction is deliberate: registry visibility answers "who can discover
this entry?", while call-time auth and policy answer "who can connect and invoke tools?".
