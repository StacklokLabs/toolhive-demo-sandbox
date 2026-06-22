import { useCallback, useEffect, useState } from 'react';
import {
  Content,
  Header,
  Page,
  Table,
  TableColumn,
  LinkButton,
  Progress,
  ResponseErrorPanel,
} from '@backstage/core-components';
import { useApi } from '@backstage/frontend-plugin-api';
import { toolhiveApiRef } from '../../api';
import { RegistryServerEntry } from '../../api/types';
import Chip from '@material-ui/core/Chip';
import TextField from '@material-ui/core/TextField';
import InputAdornment from '@material-ui/core/InputAdornment';
import FormControlLabel from '@material-ui/core/FormControlLabel';
import Checkbox from '@material-ui/core/Checkbox';
import SearchIcon from '@material-ui/icons/Search';

/** Row shape for the registry table. */
interface RegistryRow {
  name: string;
  title: string;
  description: string;
  image: string;
  transport: string;
  version: string;
  envVarCount: number;
  tags: string[];
  /** Encoded query params for the scaffolder link */
  deployLink: string;
}

/**
 * Extracts useful metadata tags from the _meta publisher-provided block.
 */
function extractTags(entry: RegistryServerEntry): string[] {
  const meta = entry.server._meta;
  if (!meta) return [];

  const publisherProvided = meta[
    'io.modelcontextprotocol.registry/publisher-provided'
  ] as Record<string, Record<string, { tags?: string[] }>> | undefined;

  if (!publisherProvided) return [];

  for (const publisherData of Object.values(publisherProvided)) {
    for (const pkgData of Object.values(publisherData)) {
      if (pkgData.tags && Array.isArray(pkgData.tags)) {
        return pkgData.tags;
      }
    }
  }
  return [];
}

function toRows(entries: RegistryServerEntry[]): RegistryRow[] {
  return entries.map(entry => {
    const s = entry.server;
    const pkg = s.packages?.[0];
    const image = pkg?.identifier ?? '';
    const transport = pkg?.transport?.type ?? 'stdio';
    const envVars = pkg?.environmentVariables ?? [];
    const tags = extractTags(entry);

    // Build scaffolder link with pre-filled parameters
    const params = new URLSearchParams();
    // Derive a short k8s-safe name from the full server name
    const shortName = s.name
      .split('/')
      .pop()!
      .replace(/[^a-z0-9-]/g, '-')
      .replace(/^-+|-+$/g, '')
      .substring(0, 63);
    params.set('formData', JSON.stringify({
      name: shortName,
      image,
      transport,
      namespace: 'mcp-workloads',
      registryTitle: s.title ?? '',
      registryDescription: s.description ?? '',
    }));

    return {
      name: s.name,
      title: s.title ?? s.name,
      description: s.description ?? '',
      image,
      transport,
      version: s.version ?? '-',
      envVarCount: envVars.length,
      tags,
      deployLink: `/create/templates/default/deploy-mcp-server?${params.toString()}`,
    };
  });
}

export const RegistryPage = () => {
  const api = useApi(toolhiveApiRef);

  const [entries, setEntries] = useState<RegistryServerEntry[]>([]);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState<Error | undefined>();
  const [search, setSearch] = useState('');
  const [latestOnly, setLatestOnly] = useState(true);

  const fetchEntries = useCallback(async () => {
    try {
      setLoading(true);
      const result = await api.listRegistryServers(
        search || undefined,
        latestOnly,
      );
      setEntries(result);
      setError(undefined);
    } catch (e) {
      setError(e instanceof Error ? e : new Error(String(e)));
    } finally {
      setLoading(false);
    }
  }, [api, search, latestOnly]);

  useEffect(() => {
    fetchEntries();
  }, [fetchEntries]);

  const columns: TableColumn<RegistryRow>[] = [
    {
      title: 'Name',
      field: 'title',
      highlight: true,
    },
    {
      title: 'Description',
      field: 'description',
      render: row => (
        <span
          title={row.description}
          style={{
            display: 'block',
            maxWidth: 350,
            overflow: 'hidden',
            textOverflow: 'ellipsis',
            whiteSpace: 'nowrap',
          }}
        >
          {row.description || '-'}
        </span>
      ),
    },
    { title: 'Transport', field: 'transport' },
    { title: 'Version', field: 'version' },
    {
      title: 'Env Vars',
      field: 'envVarCount',
      render: row =>
        row.envVarCount > 0 ? `${row.envVarCount} required` : 'None',
    },
    {
      title: 'Tags',
      field: 'tags',
      render: row =>
        row.tags.length > 0 ? (
          <div style={{ display: 'flex', flexWrap: 'wrap', gap: 4 }}>
            {row.tags.slice(0, 4).map(tag => (
              <Chip key={tag} label={tag} size="small" />
            ))}
            {row.tags.length > 4 && (
              <Chip label={`+${row.tags.length - 4}`} size="small" variant="outlined" />
            )}
          </div>
        ) : (
          <>-</>
        ),
      sorting: false,
    },
    {
      title: 'Actions',
      field: 'deployLink',
      sorting: false,
      render: row => (
        <LinkButton
          to={row.deployLink}
          color="primary"
          variant="outlined"
          size="small"
        >
          Deploy
        </LinkButton>
      ),
    },
  ];

  return (
    <Page themeId="tool">
      <Header
        title="MCP Server Registry"
        subtitle="Browse and deploy MCP servers from the ToolHive Registry"
      />
      <Content>
        <div style={{ display: 'flex', alignItems: 'center', gap: 16, marginBottom: 16 }}>
          <TextField
            placeholder="Search servers..."
            variant="outlined"
            size="small"
            value={search}
            onChange={e => setSearch(e.target.value)}
            InputProps={{
              startAdornment: (
                <InputAdornment position="start">
                  <SearchIcon />
                </InputAdornment>
              ),
            }}
            style={{ minWidth: 300 }}
          />
          <FormControlLabel
            control={
              <Checkbox
                checked={latestOnly}
                onChange={e => setLatestOnly(e.target.checked)}
                color="primary"
              />
            }
            label="Latest versions only"
          />
        </div>
        {loading && <Progress />}
        {error && <ResponseErrorPanel error={error} />}
        {!loading && !error && (
          <Table<RegistryRow>
            title={`Available MCP Servers (${entries.length})`}
            columns={columns}
            data={toRows(entries)}
            options={{
              paging: true,
              pageSize: 20,
              search: true,
              sorting: true,
            }}
          />
        )}
      </Content>
    </Page>
  );
};
