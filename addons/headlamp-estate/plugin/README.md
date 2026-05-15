# ToolHive Estate Headlamp Plugin

Cluster-local Headlamp plugin for the ToolHive estate addon.

The plugin is intentionally read-only. It calls the Kubernetes API through Headlamp,
loads ToolHive CRDs and selected `HTTPRoute` resources, and renders:

- vMCP gateway inventory
- backend workload inventory
- registry visibility vs. call-time auth
- demo persona access matrix
- tool surface summary
- findings for likely access drift

Build locally from this directory:

```sh
npm ci
npm run build
```

The parent addon packages `dist/main.js` and `package.json` into a ConfigMap mounted
at `/headlamp/plugins/toolhive-estate`.
