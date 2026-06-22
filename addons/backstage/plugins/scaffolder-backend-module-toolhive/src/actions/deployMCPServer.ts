import { createTemplateAction } from '@backstage/plugin-scaffolder-node';
import {
  API_GROUP,
  API_VERSION,
  createCustomObjectsApi,
  createMCPServer,
  waitForServerUrl,
} from './mcpServer';

const GATEWAY_API_GROUP = 'gateway.networking.k8s.io';
const GATEWAY_API_VERSION = 'v1';
const HTTPROUTE_PLURAL = 'httproutes';
const DEFAULT_GATEWAY_NAME = 'traefik-gateway';
const DEFAULT_GATEWAY_NAMESPACE = 'traefik';

/**
 * Creates a scaffolder action that deploys an MCPServer CR
 * via the ToolHive Operator.
 */
export function createDeployMCPServerAction(options?: { mcpHostname?: string }) {
  return createTemplateAction({
    id: 'toolhive:deploy:mcpserver',
    description: 'Deploy an MCP Server via ToolHive Operator',
    schema: {
      input: {
        name: z => z.string().describe('MCPServer resource name'),
        namespace: z =>
          z.string().default('mcp-workloads').describe('Kubernetes namespace'),
        image: z =>
          z.string().describe('Container image for the MCP server'),
        transport: z =>
          z
            .enum(['stdio', 'sse', 'streamable-http'])
            .default('stdio')
            .describe('MCP transport protocol'),
        port: z =>
          z
            .number()
            .optional()
            .describe('Port the MCP server listens on'),
        env: z =>
          z
            .array(z.object({ name: z.string(), value: z.string() }))
            .optional()
            .describe('Environment variables'),
        exposeViaIngress: z =>
          z
            .boolean()
            .default(false)
            .describe(
              'Create an HTTPRoute on the shared Traefik gateway so the server is reachable at mcp-<IP>.traefik.me/<path>/mcp',
            ),
        ingressPath: z =>
          z
            .string()
            .optional()
            .describe(
              'Path prefix for the HTTPRoute (defaults to /<server name>). Only used when exposeViaIngress is true.',
            ),
        registerInRegistry: z =>
          z
            .boolean()
            .default(false)
            .describe('Add registry annotations to publish this server in the ToolHive catalog'),
        registryTitle: z =>
          z.string().optional().describe('Human-readable title shown in the registry'),
        registryDescription: z =>
          z.string().optional().describe('Description shown in the registry'),
        registryAuthzClaims: z =>
          z
            .string()
            .optional()
            .describe('JSON group claims controlling registry visibility, e.g. {"groups": "engineering"}'),
      },
      output: {
        serverName: z =>
          z.string().describe('Name of the deployed MCPServer'),
        namespace: z =>
          z.string().describe('Namespace of the deployed MCPServer'),
        serverUrl: z =>
          z.string().describe('Service URL of the MCPServer'),
        ingressPath: z =>
          z
            .string()
            .optional()
            .describe('HTTPRoute path prefix, if ingress was created'),
        ingressUrl: z =>
          z
            .string()
            .optional()
            .describe(
              'Public URL the MCP server is reachable at, if ingress was created',
            ),
      },
    },
    async handler(ctx) {
      const {
        name,
        namespace,
        image,
        transport,
        port,
        env,
        exposeViaIngress,
        ingressPath,
        registerInRegistry,
        registryTitle,
        registryDescription,
        registryAuthzClaims,
      } = ctx.input;

      ctx.logger.info(
        `Deploying MCPServer "${name}" in namespace "${namespace}" with image "${image}"`,
      );

      // Connect to Kubernetes
      const customObjectsApi = createCustomObjectsApi();

      // An HTTPRoute is needed when explicitly requested OR when registering in
      // the registry (a catalog URL is meaningless without an accessible route).
      const needsIngress = exposeViaIngress || registerInRegistry;
      const rawPath = ingressPath || `/${name}`;
      let resolvedIngressPath: string | undefined;
      if (needsIngress) {
        resolvedIngressPath = rawPath.startsWith('/') ? rawPath : `/${rawPath}`;
      }

      // mcpHostname is injected at deploy time from the cluster's sslip.io
      // base hostname (e.g. "http://mcp-172-19-0-3.sslip.io"). It can't be
      // resolved from inside the cluster at runtime.
      const mcpHostname = options?.mcpHostname;

      // Build registry annotations when requested
      const annotations: Record<string, string> = {};
      if (registerInRegistry) {
        annotations['toolhive.stacklok.dev/registry-export'] = 'true';
        if (registryTitle) {
          annotations['toolhive.stacklok.dev/registry-title'] = registryTitle;
        }
        if (registryDescription) {
          annotations['toolhive.stacklok.dev/registry-description'] = registryDescription;
        }
        if (registryAuthzClaims) {
          annotations['toolhive.stacklok.dev/authz-claims'] = registryAuthzClaims;
        }
        if (resolvedIngressPath && mcpHostname) {
          annotations['toolhive.stacklok.dev/registry-url'] =
            `${mcpHostname}${resolvedIngressPath}/mcp`;
        }
      }

      // Build the MCPServer manifest
      const manifest = {
        apiVersion: `${API_GROUP}/${API_VERSION}`,
        kind: 'MCPServer',
        metadata: {
          name,
          namespace,
          ...(Object.keys(annotations).length > 0 && { annotations }),
        },
        spec: {
          image,
          ...(transport && { transport }),
          ...(port && { proxyPort: port }),
          ...(env && env.length > 0 && { env }),
        },
      };

      // Apply the MCPServer CR and wait for it to report a status URL.
      await createMCPServer(customObjectsApi, manifest, name, namespace, ctx.logger);
      const serverUrl = await waitForServerUrl(
        customObjectsApi,
        name,
        namespace,
        ctx.logger,
      );

      // Optionally create an HTTPRoute so the server is reachable through the
      // shared Traefik gateway at `/<path>/mcp`. The ToolHive operator creates
      // a Service named `mcp-<name>-proxy` on port 8080 for each MCPServer, so
      // the route mirrors the pattern used by existing demo manifests.
      if (needsIngress && resolvedIngressPath) {
        const httpRoute = {
          apiVersion: `${GATEWAY_API_GROUP}/${GATEWAY_API_VERSION}`,
          kind: 'HTTPRoute',
          metadata: {
            name: `${name}-mcp-route`,
            namespace,
            labels: {
              'app.kubernetes.io/managed-by': 'backstage',
              'toolhive.stacklok.dev/mcpserver': name,
            },
          },
          spec: {
            parentRefs: [
              {
                group: GATEWAY_API_GROUP,
                kind: 'Gateway',
                name: DEFAULT_GATEWAY_NAME,
                namespace: DEFAULT_GATEWAY_NAMESPACE,
              },
            ],
            rules: [
              {
                matches: [
                  {
                    path: {
                      type: 'PathPrefix',
                      value: resolvedIngressPath,
                    },
                  },
                ],
                filters: [
                  {
                    type: 'URLRewrite',
                    urlRewrite: {
                      path: {
                        type: 'ReplacePrefixMatch',
                        replacePrefixMatch: '/',
                      },
                    },
                  },
                ],
                backendRefs: [
                  {
                    group: '',
                    kind: 'Service',
                    name: `mcp-${name}-proxy`,
                    port: 8080,
                    weight: 1,
                  },
                ],
              },
            ],
          },
        };

        ctx.logger.info(
          `Creating HTTPRoute "${name}-mcp-route" in namespace "${namespace}" with path prefix "${resolvedIngressPath}"`,
        );
        try {
          await customObjectsApi.createNamespacedCustomObject({
            group: GATEWAY_API_GROUP,
            version: GATEWAY_API_VERSION,
            namespace,
            plural: HTTPROUTE_PLURAL,
            body: httpRoute,
          });

          if (mcpHostname) {
            const ingressUrl = `${mcpHostname}${resolvedIngressPath}/mcp`;
            ctx.logger.info(
              `MCPServer "${name}" is reachable at ${ingressUrl}`,
            );
            ctx.output('ingressUrl', ingressUrl);
          }
        } catch (error: unknown) {
          const message =
            error instanceof Error ? error.message : String(error);
          // Route creation is best-effort — don't fail the whole deploy.
          ctx.logger.warn(
            `Failed to create HTTPRoute for "${name}": ${message}`,
          );
        }
      }

      ctx.logger.info(
        `MCPServer deployment complete: name=${name}, namespace=${namespace}, url=${serverUrl}`,
      );

      ctx.output('serverName', name);
      ctx.output('namespace', namespace);
      ctx.output('serverUrl', serverUrl);
      if (resolvedIngressPath) {
        ctx.output('ingressPath', resolvedIngressPath);
      }
    },
  });
}
