# observability-tempo

Adds Grafana Tempo for distributed tracing. Without this addon, the demo's MCP servers and vMCPs still emit OTLP traces to the OTel collector, but the collector drops them (only the debug exporter is wired up). Installing this addon stands up Tempo, points the collector's traces pipeline at it, and lights up the Tempo datasource that's already provisioned in Grafana.

## What it does

- Installs the Grafana Tempo chart (singleBinary mode) into the `observability` namespace.
- Re-applies the cluster's `OpenTelemetryCollector/mcp` resource with an `otlp/tempo` exporter added to the traces pipeline. The OpenTelemetry operator rolls the collector deployment automatically.

## Prerequisites

- `bootstrap.sh` has finished (the `observability` namespace, OTel operator, and OTel collector are already in place).

## Deploy

```bash
./deploy.sh
```

## Teardown

```bash
./teardown.sh
```

Teardown re-applies `infra/otel-collector.yaml` (the core variant without the Tempo exporter) and uninstalls the Tempo Helm release. Traces continue to be accepted by the collector but are dropped.

## Notes

- The Tempo Grafana datasource is provisioned in the core Grafana values (`infra/grafana-helm-values.yaml`) regardless of whether this addon is installed. When the addon is absent, querying that datasource in Grafana Explore returns a connection error. None of the bundled dashboards reference Tempo.
- Persistence: Tempo's chart defaults are used. The PVC is removed by `teardown.sh`.
