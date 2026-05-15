import { registerRoute, registerSidebarEntry } from '@kinvolk/headlamp-plugin/lib';
import {
  Alert,
  Box,
  Chip,
  CircularProgress,
  Divider,
  Link,
  Paper,
  Stack,
  Tab,
  Table,
  TableBody,
  TableCell,
  TableContainer,
  TableHead,
  TableRow,
  Tabs,
  Typography,
} from '@mui/material';
import { useEffect, useMemo, useState } from 'react';

type AnyObject = Record<string, any>;

interface ResourceDef {
  kind: string;
  key: string;
  apiPath: string;
}

interface Persona {
  username: string;
  email: string;
  groups: string[];
}

interface FetchResult {
  resources: Record<string, AnyObject[]>;
  personas: Persona[];
  warnings: string[];
}

interface Finding {
  priority: 'P1' | 'P2' | 'P3';
  message: string;
}

const TOOLHIVE_GROUP = 'toolhive.stacklok.dev';
const TOOLHIVE_VERSION = 'v1beta1';

const RESOURCE_DEFS: ResourceDef[] = [
  {
    kind: 'MCPServer',
    key: 'mcpservers',
    apiPath: `/apis/${TOOLHIVE_GROUP}/${TOOLHIVE_VERSION}/mcpservers`,
  },
  {
    kind: 'MCPRemoteProxy',
    key: 'mcpremoteproxies',
    apiPath: `/apis/${TOOLHIVE_GROUP}/${TOOLHIVE_VERSION}/mcpremoteproxies`,
  },
  {
    kind: 'MCPServerEntry',
    key: 'mcpserverentries',
    apiPath: `/apis/${TOOLHIVE_GROUP}/${TOOLHIVE_VERSION}/mcpserverentries`,
  },
  {
    kind: 'VirtualMCPServer',
    key: 'virtualmcpservers',
    apiPath: `/apis/${TOOLHIVE_GROUP}/${TOOLHIVE_VERSION}/virtualmcpservers`,
  },
  {
    kind: 'MCPGroup',
    key: 'mcpgroups',
    apiPath: `/apis/${TOOLHIVE_GROUP}/${TOOLHIVE_VERSION}/mcpgroups`,
  },
  {
    kind: 'MCPOIDCConfig',
    key: 'mcpoidcconfigs',
    apiPath: `/apis/${TOOLHIVE_GROUP}/${TOOLHIVE_VERSION}/mcpoidcconfigs`,
  },
  {
    kind: 'MCPExternalAuthConfig',
    key: 'mcpexternalauthconfigs',
    apiPath: `/apis/${TOOLHIVE_GROUP}/${TOOLHIVE_VERSION}/mcpexternalauthconfigs`,
  },
  {
    kind: 'MCPRegistry',
    key: 'mcpregistries',
    apiPath: `/apis/${TOOLHIVE_GROUP}/${TOOLHIVE_VERSION}/mcpregistries`,
  },
  {
    kind: 'MCPTelemetryConfig',
    key: 'mcptelemetryconfigs',
    apiPath: `/apis/${TOOLHIVE_GROUP}/${TOOLHIVE_VERSION}/mcptelemetryconfigs`,
  },
  {
    kind: 'EmbeddingServer',
    key: 'embeddingservers',
    apiPath: `/apis/${TOOLHIVE_GROUP}/${TOOLHIVE_VERSION}/embeddingservers`,
  },
  {
    kind: 'VirtualMCPCompositeToolDefinition',
    key: 'virtualmcpcompositetooldefinitions',
    apiPath: `/apis/${TOOLHIVE_GROUP}/${TOOLHIVE_VERSION}/virtualmcpcompositetooldefinitions`,
  },
  {
    kind: 'HTTPRoute',
    key: 'httproutes',
    apiPath: '/apis/gateway.networking.k8s.io/v1/httproutes',
  },
];

const REGISTRY_EXPORT = 'toolhive.stacklok.dev/registry-export';
const REGISTRY_URL = 'toolhive.stacklok.dev/registry-url';
const REGISTRY_TITLE = 'toolhive.stacklok.dev/registry-title';
const AUTHZ_CLAIMS = 'toolhive.stacklok.dev/authz-claims';
const TOOL_DEFINITIONS = 'toolhive.stacklok.dev/tool-definitions';
const EXPOSED_KINDS = ['MCPServer', 'MCPRemoteProxy', 'MCPServerEntry', 'VirtualMCPServer'];
const WORKLOAD_KINDS = ['MCPServer', 'MCPRemoteProxy', 'MCPServerEntry'];

function nested(obj: AnyObject | undefined, path: string, fallback: any = ''): any {
  let current: any = obj;
  for (const part of path.split('.')) {
    if (!current || typeof current !== 'object' || !(part in current)) {
      return fallback;
    }
    current = current[part];
  }
  return current ?? fallback;
}

function meta(obj: AnyObject): AnyObject {
  return obj.metadata || {};
}

function objectName(obj: AnyObject): string {
  return meta(obj).name || '';
}

function namespace(obj: AnyObject): string {
  return meta(obj).namespace || '';
}

function namespacedName(obj: AnyObject): string {
  return `${namespace(obj)}/${objectName(obj)}`;
}

function annotations(obj: AnyObject): Record<string, string> {
  return meta(obj).annotations || {};
}

function annotation(obj: AnyObject, key: string): string {
  return annotations(obj)[key] || '';
}

function isExported(obj: AnyObject): boolean {
  return annotation(obj, REGISTRY_EXPORT).toLowerCase() === 'true';
}

function parseJsonAnnotation(obj: AnyObject, key: string): any {
  const raw = annotation(obj, key);
  if (!raw) return undefined;
  try {
    return JSON.parse(raw);
  } catch {
    return undefined;
  }
}

function claims(obj: AnyObject): AnyObject {
  const parsed = parseJsonAnnotation(obj, AUTHZ_CLAIMS);
  return parsed && typeof parsed === 'object' && !Array.isArray(parsed) ? parsed : {};
}

function claimGroups(value: AnyObject): string[] {
  const groups = value.groups;
  if (!groups) return [];
  if (Array.isArray(groups)) {
    return groups.map(item => String(item).replace(/^\//, '')).filter(Boolean);
  }
  return String(groups)
    .split(/[,\s]+/)
    .map(item => item.trim().replace(/^\//, ''))
    .filter(Boolean);
}

function claimsLabel(obj: AnyObject): string {
  const groups = claimGroups(claims(obj));
  if (groups.length > 0) return groups.join(', ');
  return isExported(obj) ? 'default/source' : 'not exported';
}

function tools(obj: AnyObject): AnyObject[] {
  const parsed = parseJsonAnnotation(obj, TOOL_DEFINITIONS);
  return Array.isArray(parsed) ? parsed.filter(item => item && typeof item === 'object') : [];
}

function title(obj: AnyObject): string {
  return annotation(obj, REGISTRY_TITLE) || objectName(obj);
}

function groupRef(obj: AnyObject): string {
  return nested(obj, 'spec.groupRef.name', '');
}

function phase(obj: AnyObject): string {
  return nested(obj, 'status.phase', '') || nested(obj, 'status.status', '');
}

function conditionStatus(obj: AnyObject, type: string): string {
  const conditions = nested(obj, 'status.conditions', []) as AnyObject[];
  return conditions.find(condition => condition.type === type)?.status || '';
}

function statusLabel(obj: AnyObject): string {
  return phase(obj) || (nested(obj, 'status.ready', '') ? `Ready=${nested(obj, 'status.ready')}` : '') ||
    (conditionStatus(obj, 'Valid') ? `Valid=${conditionStatus(obj, 'Valid')}` : '') ||
    (conditionStatus(obj, 'ConfigurationValid')
      ? `ConfigurationValid=${conditionStatus(obj, 'ConfigurationValid')}`
      : '');
}

function isReadyLike(obj: AnyObject): boolean {
  return (
    phase(obj) === 'Ready' ||
    String(nested(obj, 'status.ready', '')).toLowerCase() === 'true' ||
    conditionStatus(obj, 'Valid').toLowerCase() === 'true' ||
    conditionStatus(obj, 'ConfigurationValid').toLowerCase() === 'true'
  );
}

function authzConfig(kind: string, obj: AnyObject): AnyObject | undefined {
  return kind === 'VirtualMCPServer'
    ? nested(obj, 'spec.incomingAuth.authzConfig', undefined)
    : nested(obj, 'spec.authzConfig', undefined);
}

function inlinePolicies(config: AnyObject | undefined): string[] {
  const policies = nested(config, 'inline.policies', []);
  return Array.isArray(policies) ? policies.map(policy => String(policy)) : [];
}

function policySummary(kind: string, obj: AnyObject): string {
  const config = authzConfig(kind, obj);
  if (!config) return 'none';
  const policies = inlinePolicies(config);
  if (policies.length === 0) return config.type || 'configured';
  const joined = policies.join('\n');
  const groups = Array.from(joined.matchAll(/THVGroup::"([^"]+)"/g)).map(match => match[1]);
  const resourcePatterns = Array.from(joined.matchAll(/resource\.name\s+like\s+"([^"]+)"/g)).map(
    match => match[1]
  );
  const parts = [`${config.type || 'inline'}: ${policies.length} policies`];
  if (groups.length) parts.push(`groups ${Array.from(new Set(groups)).join(', ')}`);
  if (resourcePatterns.length) parts.push(`resources ${Array.from(new Set(resourcePatterns)).join(', ')}`);
  const upstream = nested(config, 'inline.primaryUpstreamProvider', '');
  if (upstream) parts.push(`upstream ${upstream}`);
  return parts.join('; ');
}

function authSummary(kind: string, obj: AnyObject): string {
  if (kind === 'VirtualMCPServer') {
    const type = nested(obj, 'spec.incomingAuth.type', '');
    if (type === 'anonymous') return 'anonymous';
    const oidc = nested(obj, 'spec.incomingAuth.oidcConfigRef.name', '');
    return [type || 'unspecified', oidc ? `via ${oidc}` : '', authzConfig(kind, obj) ? '+ Cedar' : '']
      .filter(Boolean)
      .join(' ');
  }
  const parts = [];
  const oidc = nested(obj, 'spec.oidcConfigRef.name', '');
  const authServer = nested(obj, 'spec.authServerRef.name', '');
  if (oidc) parts.push(`OIDC via ${oidc}`);
  if (authServer) parts.push(`embedded AS ${authServer}`);
  if (authzConfig(kind, obj)) parts.push('Cedar');
  return parts.join(' + ') || 'none';
}

function hasCallTimeAuth(kind: string, obj: AnyObject): boolean {
  if (kind === 'VirtualMCPServer') {
    return nested(obj, 'spec.incomingAuth.type', '') !== 'anonymous';
  }
  return Boolean(nested(obj, 'spec.oidcConfigRef.name', '') || nested(obj, 'spec.authServerRef.name', ''));
}

function outgoingAuth(kind: string, obj: AnyObject): string {
  if (kind === 'VirtualMCPServer') return nested(obj, 'spec.outgoingAuth.source', '') || 'none';
  return nested(obj, 'spec.externalAuthConfigRef.name', '') || 'none';
}

function serviceNameFromUrl(url: string): string {
  try {
    return new URL(url).hostname.split('.')[0];
  } catch {
    return '';
  }
}

function routeIndex(routes: AnyObject[]): Record<string, string[]> {
  const byBackend: Record<string, string[]> = {};
  for (const route of routes) {
    for (const rule of nested(route, 'spec.rules', [])) {
      const paths = (rule.matches || [])
        .map((match: AnyObject) => nested(match, 'path.value', ''))
        .filter(Boolean);
      for (const backend of rule.backendRefs || []) {
        if (!backend.name) continue;
        const label = `${namespacedName(route)} ${paths.join(', ')}`.trim();
        byBackend[backend.name] = [...(byBackend[backend.name] || []), label];
      }
    }
  }
  return byBackend;
}

function personaCanSee(persona: Persona, obj: AnyObject): string {
  if (!isExported(obj)) return '';
  const groups = claimGroups(claims(obj));
  if (groups.length === 0) return '?';
  return groups.some(group => persona.groups.includes(group)) ? 'yes' : 'no';
}

function registryPublicHasK8s(registries: AnyObject[]): boolean {
  const yaml = nested(registries[0], 'spec.configYAML', '');
  return /-\s+name:\s+public\b[\s\S]*?-\s+k8s\b/.test(yaml);
}

function registrySuperAdmins(registries: AnyObject[]): string {
  const yaml = nested(registries[0], 'spec.configYAML', '');
  return Array.from(yaml.matchAll(/preferred_username:\s*([^\s]+)/g))
    .map(match => match[1].replace(/['"]/g, ''))
    .join(', ');
}

function buildFindings(resources: Record<string, AnyObject[]>): Finding[] {
  const findings: Finding[] = [];
  for (const kind of EXPOSED_KINDS) {
    for (const obj of resources[kind] || []) {
      if (!isExported(obj)) continue;
      const label = `${kind} ${namespacedName(obj)}`;
      const toolNames = tools(obj).map(tool => String(tool.name || ''));
      const changingTools = toolNames.filter(tool =>
        /(^|_)(apply|delete|create|update|merge|post|write)_?/.test(tool)
      );
      if (!hasCallTimeAuth(kind, obj)) {
        findings.push({
          priority: 'P2',
          message: `${label} has registry visibility controls but no ToolHive call-time auth.`,
        });
      }
      if (!hasCallTimeAuth(kind, obj) && changingTools.length > 0) {
        findings.push({
          priority: 'P1',
          message: `${label} exposes state-changing tools without call-time auth: ${changingTools
            .slice(0, 6)
            .join(', ')}${changingTools.length > 6 ? ' ...' : ''}`,
        });
      }
      if (!annotation(obj, REGISTRY_URL)) {
        findings.push({ priority: 'P3', message: `${label} is registry-exported without registry-url.` });
      }
      if (tools(obj).length === 0) {
        findings.push({
          priority: 'P3',
          message: `${label} is registry-exported without parsed tool-definitions.`,
        });
      }
    }
  }
  for (const obj of resources.MCPOIDCConfig || []) {
    if (nested(obj, 'spec.inline.insecureAllowHTTP', false)) {
      findings.push({
        priority: 'P3',
        message: `MCPOIDCConfig ${namespacedName(obj)} allows insecure HTTP.`,
      });
    }
    if (nested(obj, 'spec.inline.jwksAllowPrivateIP', false)) {
      findings.push({
        priority: 'P3',
        message: `MCPOIDCConfig ${namespacedName(obj)} allows JWKS private IPs.`,
      });
    }
  }
  if (registryPublicHasK8s(resources.MCPRegistry || [])) {
    findings.push({
      priority: 'P2',
      message: 'The public registry includes the k8s source, so exported in-cluster entries are listed without auth.',
    });
  }
  return findings.sort((a, b) => a.priority.localeCompare(b.priority));
}

function listItems(value: AnyObject[] | AnyObject | undefined): AnyObject[] {
  if (Array.isArray(value)) return value;
  return Array.isArray(value?.items) ? value.items : [];
}

function personasFromKeycloakConfigMap(cm: AnyObject | undefined): Persona[] {
  try {
    const raw = Object.values(cm?.data || {}).find(
      value => typeof value === 'string' && value.includes('"users"') && value.includes('"realm"')
    ) as string | undefined;
    if (!raw) return [];
    const realm = JSON.parse(raw);
    return (realm.users || [])
      .map((user: AnyObject) => ({
        username: user.username,
        email: user.email || '',
        groups: (user.groups || []).map((group: string) => group.replace(/^\//, '')).sort(),
      }))
      .sort((a: Persona, b: Persona) => a.username.localeCompare(b.username));
  } catch {
    return [];
  }
}

async function loadEstate(): Promise<FetchResult> {
  const response = await fetch('/estate-api', {
    headers: { Accept: 'application/json' },
    cache: 'no-store',
  });
  if (!response.ok) {
    throw new Error(`Estate API returned ${response.status}`);
  }
  const payload = await response.json();
  const resources: Record<string, AnyObject[]> = {};
  for (const def of RESOURCE_DEFS) {
    resources[def.kind] = listItems(payload.resources?.[def.kind]);
  }
  return {
    resources,
    personas: Array.isArray(payload.personas)
      ? payload.personas
      : personasFromKeycloakConfigMap(payload.keycloakConfigMap),
    warnings: Array.isArray(payload.warnings) ? payload.warnings : [],
  };
}

function Stat({ label, value, tone }: { label: string; value: number | string; tone?: 'warning' | 'error' }) {
  return (
    <Paper variant="outlined" sx={{ p: 1.5, minWidth: 150 }}>
      <Typography variant="caption" color="text.secondary">
        {label}
      </Typography>
      <Typography color={tone === 'error' ? 'error.main' : tone === 'warning' ? 'warning.main' : 'text.primary'} variant="h5">
        {value}
      </Typography>
    </Paper>
  );
}

function DataTable({ headers, rows }: { headers: string[]; rows: React.ReactNode[][] }) {
  if (rows.length === 0) {
    return <Typography color="text.secondary">No rows.</Typography>;
  }
  return (
    <TableContainer component={Paper} variant="outlined">
      <Table size="small" stickyHeader>
        <TableHead>
          <TableRow>
            {headers.map(header => (
              <TableCell key={header} sx={{ fontWeight: 700 }}>
                {header}
              </TableCell>
            ))}
          </TableRow>
        </TableHead>
        <TableBody>
          {rows.map((row, index) => (
            <TableRow hover key={index}>
              {row.map((cell, cellIndex) => (
                <TableCell key={cellIndex}>{cell}</TableCell>
              ))}
            </TableRow>
          ))}
        </TableBody>
      </Table>
    </TableContainer>
  );
}

function StatusChip({ value }: { value: string }) {
  const ready = value === 'Ready' || value === 'Ready=True' || value === 'Valid=True';
  return <Chip size="small" color={ready ? 'success' : 'default'} label={value || 'unknown'} />;
}

function AuthChip({ value }: { value: string }) {
  const anonymous = value === 'anonymous' || value === 'none';
  return <Chip size="small" color={anonymous ? 'warning' : 'success'} variant={anonymous ? 'outlined' : 'filled'} label={value} />;
}

function Findings({ findings }: { findings: Finding[] }) {
  if (!Array.isArray(findings) || findings.length === 0) {
    return <Typography color="text.secondary">No findings.</Typography>;
  }
  return (
    <Stack spacing={1}>
      {findings.map((finding, index) => {
        const severity =
          finding.priority === 'P1' ? 'error' : finding.priority === 'P2' ? 'warning' : 'info';
        return (
          <Alert key={`${finding.priority}-${index}`} severity={severity}>
            <Typography component="span" sx={{ fontWeight: 700, mr: 1 }}>
              {finding.priority}
            </Typography>
            <Typography component="span">{finding.message}</Typography>
          </Alert>
        );
      })}
    </Stack>
  );
}

function ToolHiveEstate() {
  const [tab, setTab] = useState(0);
  const [data, setData] = useState<FetchResult | null>(null);
  const [error, setError] = useState<string | null>(null);

  useEffect(() => {
    loadEstate()
      .then(setData)
      .catch(err => setError(err?.message || String(err)));
  }, []);

  const model = useMemo(() => {
    if (!data) return null;
    const { resources } = data;
    const routes = routeIndex(resources.HTTPRoute || []);
    const findings = buildFindings(resources);
    const exported = EXPOSED_KINDS.flatMap(kind => (resources[kind] || []).map(obj => ({ kind, obj }))).filter(
      item => isExported(item.obj)
    );
    return { resources, routes, findings, exported };
  }, [data]);

  if (error) {
    return <Alert severity="error">{error}</Alert>;
  }
  if (!data || !model) {
    return (
      <Stack alignItems="center" spacing={2} sx={{ py: 6 }}>
        <CircularProgress />
        <Typography>Loading ToolHive estate...</Typography>
      </Stack>
    );
  }

  const { resources, routes, findings, exported } = model;
  const readyObjects = RESOURCE_DEFS.filter(def => def.kind !== 'HTTPRoute').reduce(
    (sum, def) => sum + (resources[def.kind] || []).filter(isReadyLike).length,
    0
  );
  const gatewayRows = (resources.VirtualMCPServer || []).map(obj => {
    const service = serviceNameFromUrl(nested(obj, 'status.url', ''));
    return [
      namespacedName(obj),
      title(obj),
      groupRef(obj),
      nested(obj, 'status.backendCount', ''),
      <AuthChip value={authSummary('VirtualMCPServer', obj)} />,
      claimsLabel(obj),
      tools(obj).length,
      statusLabel(obj) ? <StatusChip value={statusLabel(obj)} /> : 'unknown',
      (routes[service] || []).join('; ') || '-',
    ];
  });

  const workloadRows = WORKLOAD_KINDS.flatMap(kind =>
    (resources[kind] || []).map(obj => [
      kind,
      namespacedName(obj),
      groupRef(obj) || '-',
      nested(obj, 'spec.remoteUrl', '') || nested(obj, 'spec.image', '') || annotation(obj, REGISTRY_URL) || '-',
      <AuthChip value={authSummary(kind, obj)} />,
      outgoingAuth(kind, obj),
      claimsLabel(obj),
      statusLabel(obj) ? <StatusChip value={statusLabel(obj)} /> : 'unknown',
    ])
  );

  const groupRows = (resources.MCPGroup || []).map(group => {
    const key = namespacedName(group);
    const members = WORKLOAD_KINDS.map(kind => {
      const names = (resources[kind] || [])
        .filter(obj => `${namespace(obj)}/${groupRef(obj)}` === key)
        .map(objectName);
      return names.length ? `${kind}: ${names.join(', ')}` : '';
    }).filter(Boolean);
    const frontends = (resources.VirtualMCPServer || [])
      .filter(obj => `${namespace(obj)}/${groupRef(obj)}` === key)
      .map(objectName);
    return [key, nested(group, 'spec.description', ''), frontends.join(', ') || '-', members.join('; ') || '-', statusLabel(group)];
  });

  const accessRows = exported.map(({ kind, obj }) => [
    kind,
    namespacedName(obj),
    title(obj),
    claimsLabel(obj),
    ...data.personas.map(persona => personaCanSee(persona, obj)),
    <AuthChip value={authSummary(kind, obj)} />,
    policySummary(kind, obj),
  ]);

  const toolRows = exported.map(({ kind, obj }) => {
    const toolNames = tools(obj).map(tool => tool.name).filter(Boolean);
    return [
      kind,
      namespacedName(obj),
      toolNames.length,
      toolNames.slice(0, 8).join(', ') + (toolNames.length > 8 ? ' ...' : ''),
    ];
  });

  const authRows = [...(resources.MCPOIDCConfig || []), ...(resources.MCPExternalAuthConfig || [])].map(obj => [
    obj.kind,
    namespacedName(obj),
    nested(obj, 'spec.type', ''),
    nested(obj, 'spec.inline.issuer', '') || nested(obj, 'spec.embeddedAuthServer.issuer', '') || '-',
    (nested(obj, 'status.referencingWorkloads', []) || [])
      .map((ref: AnyObject) => `${ref.kind}/${ref.name}`)
      .join(', ') || '-',
    statusLabel(obj),
  ]);

  return (
    <Box sx={{ p: 2 }}>
      <Stack spacing={2}>
        <Stack direction="row" alignItems="center" justifyContent="space-between" spacing={2}>
          <Box>
            <Typography variant="h5">ToolHive Estate</Typography>
            <Typography variant="body2" color="text.secondary">
              Registry visibility and call-time enforcement are shown separately.
            </Typography>
          </Box>
          <Chip label={`Registry super admin: ${registrySuperAdmins(resources.MCPRegistry || []) || 'unknown'}`} />
        </Stack>

        {data.warnings.length > 0 && (
          <Alert severity="warning">{data.warnings.slice(0, 3).join(' | ')}</Alert>
        )}

        <Stack direction="row" flexWrap="wrap" gap={1.5}>
          <Stat label="MCP servers" value={(resources.MCPServer || []).length} />
          <Stat label="Remote proxies" value={(resources.MCPRemoteProxy || []).length} />
          <Stat label="vMCP gateways" value={(resources.VirtualMCPServer || []).length} />
          <Stat label="Ready resources" value={readyObjects} />
          <Stat label="Exported entries" value={exported.length} />
          <Stat label="P1 findings" value={findings.filter(item => item.priority === 'P1').length} tone="error" />
          <Stat label="Anonymous exported" value={exported.filter(item => !hasCallTimeAuth(item.kind, item.obj)).length} tone="warning" />
        </Stack>

        <Paper variant="outlined">
          <Tabs value={tab} onChange={(_, value) => setTab(value)} variant="scrollable" scrollButtons="auto">
            <Tab label="Gateways" />
            <Tab label="Workloads" />
            <Tab label="Access" />
            <Tab label="Findings" />
            <Tab label="Groups" />
            <Tab label="Tools" />
            <Tab label="Auth" />
          </Tabs>
        </Paper>

        {tab === 0 && (
          <DataTable
            headers={['Gateway', 'Title', 'Group', 'Backends', 'Call-time auth', 'Registry claims', 'Tools', 'Status', 'Routes']}
            rows={gatewayRows}
          />
        )}
        {tab === 1 && (
          <DataTable
            headers={['Kind', 'Name', 'Group', 'Image/Remote', 'Call-time auth', 'Outgoing auth', 'Registry claims', 'Status']}
            rows={workloadRows}
          />
        )}
        {tab === 2 && (
          <Stack spacing={1.5}>
            <DataTable
              headers={[
                'Kind',
                'Name',
                'Title',
                'Registry claims',
                ...data.personas.map(persona => persona.username),
                'Call-time auth',
                'Policy summary',
              ]}
              rows={accessRows}
            />
            <Typography variant="caption" color="text.secondary">
              `yes` means persona groups match registry claims. Endpoint auth and Cedar policy are evaluated separately.
            </Typography>
          </Stack>
        )}
        {tab === 3 && <Findings findings={findings} />}
        {tab === 4 && (
          <DataTable headers={['MCPGroup', 'Description', 'vMCP front ends', 'Backends', 'Status']} rows={groupRows} />
        )}
        {tab === 5 && <DataTable headers={['Kind', 'Name', 'Advertised tools', 'Sample']} rows={toolRows} />}
        {tab === 6 && (
          <Stack spacing={1.5}>
            <DataTable headers={['Kind', 'Name', 'Type', 'Issuer', 'Referenced by', 'Status']} rows={authRows} />
            <Divider />
            <Typography variant="body2" color="text.secondary">
              Public registry includes Kubernetes source:{' '}
              <strong>{registryPublicHasK8s(resources.MCPRegistry || []) ? 'yes' : 'no'}</strong>
            </Typography>
            <Link href="https://docs.stacklok.com/toolhive/reference/crds/" target="_blank" rel="noreferrer">
              ToolHive CRD reference
            </Link>
          </Stack>
        )}
      </Stack>
    </Box>
  );
}

registerSidebarEntry({
  parent: null,
  name: 'toolhive-estate',
  label: 'ToolHive Estate',
  url: '/toolhive-estate',
  useClusterURL: false,
  icon: 'mdi:hexagon-multiple-outline',
  sidebar: 'HOME',
});

registerRoute({
  path: '/toolhive-estate',
  sidebar: {
    item: 'toolhive-estate',
    sidebar: 'HOME',
  },
  name: 'toolhive-estate',
  exact: true,
  useClusterURL: false,
  noAuthRequired: true,
  component: ToolHiveEstate,
});
