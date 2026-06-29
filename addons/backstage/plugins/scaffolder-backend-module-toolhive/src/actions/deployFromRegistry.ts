import { createTemplateAction } from '@backstage/plugin-scaffolder-node';
import {
  API_GROUP,
  API_VERSION,
  createCustomObjectsApi,
  createMCPServer,
  waitForServerUrl,
} from './mcpServer';

interface RegistryPackage {
  identifier: string;
  transport: { type: string };
  environmentVariables?: Array<{
    name: string;
    description?: string;
    isRequired?: boolean;
    isSecret?: boolean;
  }>;
}

interface RegistryServerEntry {
  server: {
    name: string;
    description?: string;
    title?: string;
    packages: RegistryPackage[];
  };
}

interface RegistryResponse {
  servers: RegistryServerEntry[];
}

/**
 * Creates a scaffolder action that looks up an MCP server in the
 * ToolHive Registry and deploys it as an MCPServer CR.
 */
export function createDeployFromRegistryAction(options?: {
  registryUrl?: string;
  registryName?: string;
}) {
  return createTemplateAction({
    id: 'toolhive:registry:deploy',
    description:
      'Look up an MCP Server in the ToolHive Registry and deploy it via the ToolHive Operator',
    schema: {
      input: {
        serverName: z =>
          z
            .string()
            .describe(
              'Registry server name (e.g. io.github.stacklok/fetch-mcp-server)',
            ),
        deployName: z =>
          z
            .string()
            .optional()
            .describe(
              'Kubernetes resource name override (derived from serverName if omitted)',
            ),
        namespace: z =>
          z
            .string()
            .default('mcp-workloads')
            .describe('Kubernetes namespace'),
        env: z =>
          z
            .array(z.object({ name: z.string(), value: z.string() }))
            .optional()
            .describe('Environment variable overrides'),
      },
      output: {
        serverName: z =>
          z.string().describe('Name of the deployed MCPServer'),
        namespace: z =>
          z.string().describe('Namespace of the deployed MCPServer'),
        serverUrl: z =>
          z.string().describe('Service URL of the MCPServer'),
        image: z =>
          z.string().describe('Container image used'),
        transport: z =>
          z.string().describe('Transport protocol'),
      },
    },
    async handler(ctx) {
      const { serverName, deployName, namespace, env } = ctx.input;

      const registryUrl =
        options?.registryUrl ||
        'http://registry-server.toolhive-system.svc.cluster.local:8080';
      const registryName = options?.registryName || 'public';

      // Step 1: Look up the server in the registry
      ctx.logger.info(
        `Looking up "${serverName}" in ToolHive Registry "${registryName}" at ${registryUrl}`,
      );

      const searchUrl = `${registryUrl}/registry/${registryName}/v0.1/servers?search=${encodeURIComponent(serverName)}&limit=50`;
      const registryResponse = await fetch(searchUrl);

      if (!registryResponse.ok) {
        throw new Error(
          `Registry lookup failed: ${registryResponse.status} ${registryResponse.statusText}`,
        );
      }

      const registryData: RegistryResponse = await registryResponse.json();

      // Find exact match or closest match
      const match = registryData.servers.find(
        e => e.server.name === serverName,
      );

      if (!match) {
        const available = registryData.servers
          .slice(0, 5)
          .map(e => e.server.name)
          .join(', ');
        throw new Error(
          `Server "${serverName}" not found in registry. Similar: ${available || 'none'}`,
        );
      }

      const pkg = match.server.packages[0];
      if (!pkg) {
        throw new Error(
          `Server "${serverName}" has no packages in the registry`,
        );
      }

      const image = pkg.identifier;
      const transport = pkg.transport.type;

      ctx.logger.info(
        `Found registry entry: image=${image}, transport=${transport}`,
      );

      // Step 2: Derive the k8s resource name
      const name =
        deployName ||
        serverName
          .split('/')
          .pop()!
          .replace(/[^a-z0-9-]/g, '-')
          .replace(/^-+|-+$/g, '')
          .substring(0, 63);

      // Step 3: Build the MCPServer manifest
      const envVars = env && env.length > 0 ? env : undefined;

      const manifest = {
        apiVersion: `${API_GROUP}/${API_VERSION}`,
        kind: 'MCPServer',
        metadata: {
          name,
          namespace,
          labels: {
            'toolhive.stacklok.dev/registry-source': 'true',
          },
          annotations: {
            'toolhive.stacklok.dev/registry-name': serverName,
          },
        },
        spec: {
          image,
          ...(transport && { transport }),
          ...(envVars && { env: envVars }),
        },
      };

      // Step 4: Apply the MCPServer CR and wait for it to report a status URL.
      const customObjectsApi = createCustomObjectsApi();
      await createMCPServer(customObjectsApi, manifest, name, namespace, ctx.logger);
      const serverUrl = await waitForServerUrl(
        customObjectsApi,
        name,
        namespace,
        ctx.logger,
      );

      ctx.output('serverName', name);
      ctx.output('namespace', namespace);
      ctx.output('serverUrl', serverUrl);
      ctx.output('image', image);
      ctx.output('transport', transport);
    },
  });
}
