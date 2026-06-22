import { useCallback, useEffect, useState } from 'react';
import {
  Content,
  Header,
  Page,
  Table,
  TableColumn,
  StatusOK,
  StatusPending,
  StatusError,
  StatusAborted,
  StatusRunning,
  LinkButton,
  Progress,
  ResponseErrorPanel,
} from '@backstage/core-components';
import { useApi } from '@backstage/frontend-plugin-api';
import { toolhiveApiRef } from '../../api';
import { MCPServer } from '../../api/types';
import { serverDetailRouteRef } from '../../routes';
import { useRouteRef } from '@backstage/frontend-plugin-api';

const REFRESH_INTERVAL_MS = 10_000;

/** Render a colored status indicator based on MCPServer phase. */
function PhaseStatus({ phase }: { phase?: string }) {
  switch (phase) {
    case 'Ready':
      return <StatusOK>Ready</StatusOK>;
    case 'Pending':
      return <StatusPending>Pending</StatusPending>;
    case 'Failed':
      return <StatusError>Failed</StatusError>;
    case 'Terminating':
      return <StatusRunning>Terminating</StatusRunning>;
    case 'Stopped':
      return <StatusAborted>Stopped</StatusAborted>;
    default:
      return <StatusPending>Unknown</StatusPending>;
  }
}

/** Flatten an MCPServer into a row shape for the table. */
interface ServerRow {
  name: string;
  namespace: string;
  image: string;
  transport: string;
  phase: string;
  url: string;
  replicas: string;
}

function toRows(servers: MCPServer[]): ServerRow[] {
  return servers.map(s => ({
    name: s.metadata.name,
    namespace: s.metadata.namespace,
    image: s.spec.image,
    transport: s.spec.transport ?? 'stdio',
    phase: s.status?.phase ?? 'Unknown',
    url: s.status?.url ?? '-',
    replicas:
      s.status?.readyReplicas !== undefined
        ? `${s.status.readyReplicas}/${s.spec.replicas ?? 1}`
        : '-',
  }));
}

export const MCPServerListPage = () => {
  const api = useApi(toolhiveApiRef);
  const detailRoute = useRouteRef(serverDetailRouteRef);

  const [servers, setServers] = useState<MCPServer[]>([]);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState<Error | undefined>();

  const fetchServers = useCallback(async () => {
    try {
      const result = await api.listServers();
      setServers(result);
      setError(undefined);
    } catch (e) {
      setError(e instanceof Error ? e : new Error(String(e)));
    } finally {
      setLoading(false);
    }
  }, [api]);

  useEffect(() => {
    fetchServers();
    const interval = setInterval(fetchServers, REFRESH_INTERVAL_MS);
    return () => clearInterval(interval);
  }, [fetchServers]);

  const columns: TableColumn<ServerRow>[] = [
    {
      title: 'Name',
      field: 'name',
      highlight: true,
      render: row => {
        if (detailRoute) {
          return (
            <a
              href={detailRoute({
                namespace: row.namespace,
                name: row.name,
              })}
            >
              {row.name}
            </a>
          );
        }
        return <>{row.name}</>;
      },
    },
    { title: 'Namespace', field: 'namespace' },
    { title: 'Image', field: 'image' },
    { title: 'Transport', field: 'transport' },
    {
      title: 'Phase',
      field: 'phase',
      render: row => <PhaseStatus phase={row.phase} />,
    },
    {
      title: 'URL',
      field: 'url',
      render: row =>
        row.url !== '-' ? (
          <a href={row.url} target="_blank" rel="noopener noreferrer">
            {row.url}
          </a>
        ) : (
          <>-</>
        ),
    },
    { title: 'Replicas', field: 'replicas' },
  ];

  return (
    <Page themeId="tool">
      <Header title="MCP Servers" subtitle="ToolHive MCP Server Dashboard" />
      <Content>
        {loading && <Progress />}
        {error && <ResponseErrorPanel error={error} />}
        {!loading && !error && (
          <>
            <div style={{ marginBottom: 16, display: 'flex', gap: 8 }}>
              <LinkButton
                to="/create/templates/default/deploy-mcp-server"
                color="primary"
                variant="contained"
              >
                Deploy MCP Server
              </LinkButton>
              <LinkButton
                to="/toolhive/registry"
                color="default"
                variant="outlined"
              >
                Browse Registry
              </LinkButton>
            </div>
            <Table<ServerRow>
              title="Deployed MCP Servers"
              columns={columns}
              data={toRows(servers)}
              options={{
                paging: true,
                pageSize: 20,
                search: true,
                sorting: true,
              }}
            />
          </>
        )}
      </Content>
    </Page>
  );
};
