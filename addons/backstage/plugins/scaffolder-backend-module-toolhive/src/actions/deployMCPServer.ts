import { createTemplateAction } from '@backstage/plugin-scaffolder-node';
import * as k8s from '@kubernetes/client-node';

const API_GROUP = 'toolhive.stacklok.dev';
const API_VERSION = 'v1beta1';
const PLURAL = 'mcpservers';

const GATEWAY_API_GROUP = 'gateway.networking.k8s.io';
const GATEWAY_API_VERSION = 'v1';
const HTTPROUTE_PLURAL = 'httproutes';
const GATEWAY_PLURAL = 'gateways';
const DEFAULT_GATEWAY_NAME = 'traefik-gateway';
const DEFAULT_GATEWAY_NAMESPACE = 'traefik';

/**
 * Fetch the Traefik gateway's external IP and convert it into the
 * corresponding traefik.me hostname (e.g. `172.20.0.3` →
 * `mcp-172-20-0-3.traefik.me`). Returns undefined if the gateway has no
 * address yet.
 */
async function resolveTraefikHostname(
  customObjectsApi: k8s.CustomObjectsApi,
): Promise<string | undefined> {
  try {
    const gateway = (await customObjectsApi.getNamespacedCustomObject({
      group: GATEWAY_API_GROUP,
      version: GATEWAY_API_VERSION,
      namespace: DEFAULT_GATEWAY_NAMESPACE,
      plural: GATEWAY_PLURAL,
      name: DEFAULT_GATEWAY_NAME,
    })) as unknown as {
      status?: { addresses?: Array<{ value?: string }> };
    };

    const ip = gateway?.status?.addresses?.[0]?.value;
    if (!ip) return undefined;
    return `mcp-${ip.replace(/\./g, '-')}.traefik.me`;
  } catch {
    return undefined;
  }
}

/**
 * Creates a scaffolder action that deploys an MCPServer CR
 * via the ToolHive Operator.
 */
export function createDeployMCPServerAction() {
  return createTemplateAction({
    id: 'toolhive:deploy:mcpserver',
    description: 'Deploy an MCP Server via ToolHive Operator',
    schema: {
      input: {
        name: z => z.string().describe('MCPServer resource name'),
        namespace: z =>
          z.string().default('default').describe('Kubernetes namespace'),
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
      } = ctx.input;

      ctx.logger.info(
        `Deploying MCPServer "${name}" in namespace "${namespace}" with image "${image}"`,
      );

      // Build the MCPServer manifest
      const manifest = {
        apiVersion: `${API_GROUP}/${API_VERSION}`,
        kind: 'MCPServer',
        metadata: {
          name,
          namespace,
        },
        spec: {
          image,
          ...(transport && { transport }),
          ...(port && { proxyPort: port }),
          ...(env && env.length > 0 && { env }),
        },
      };

      // Connect to Kubernetes
      const kc = new k8s.KubeConfig();
      kc.loadFromDefault();
      const customObjectsApi = kc.makeApiClient(k8s.CustomObjectsApi);

      // Apply the MCPServer CR
      ctx.logger.info(
        `Creating MCPServer CR "${name}" in namespace "${namespace}"`,
      );
      try {
        await customObjectsApi.createNamespacedCustomObject({
          group: API_GROUP,
          version: API_VERSION,
          namespace,
          plural: PLURAL,
          body: manifest,
        });
      } catch (error: unknown) {
        const message =
          error instanceof Error ? error.message : String(error);
        ctx.logger.error(`Failed to create MCPServer: ${message}`);
        throw new Error(`Failed to create MCPServer "${name}": ${message}`);
      }

      ctx.logger.info(
        `MCPServer CR "${name}" created, waiting for status...`,
      );

      // Poll for the status URL (up to 30 seconds)
      let serverUrl = '';
      const pollInterval = 2000;
      const maxAttempts = 15;

      for (let attempt = 0; attempt < maxAttempts; attempt++) {
        try {
          const response =
            (await customObjectsApi.getNamespacedCustomObject({
              group: API_GROUP,
              version: API_VERSION,
              namespace,
              plural: PLURAL,
              name,
            })) as {
              status?: { phase?: string; url?: string };
            };

          const status = response?.status;
          if (status?.url) {
            serverUrl = status.url;
            ctx.logger.info(
              `MCPServer "${name}" is ready at ${serverUrl}`,
            );
            break;
          }

          const phase = status?.phase || 'Unknown';
          ctx.logger.info(
            `MCPServer "${name}" phase: ${phase} (attempt ${attempt + 1}/${maxAttempts})`,
          );

          if (phase === 'Failed') {
            throw new Error(
              `MCPServer "${name}" entered Failed phase`,
            );
          }
        } catch (error: unknown) {
          if (
            error instanceof Error &&
            error.message.includes('Failed phase')
          ) {
            throw error;
          }
          ctx.logger.warn(
            `Failed to get MCPServer status (attempt ${attempt + 1}): ${error instanceof Error ? error.message : String(error)}`,
          );
        }

        await new Promise(resolve => setTimeout(resolve, pollInterval));
      }

      if (!serverUrl) {
        ctx.logger.warn(
          `MCPServer "${name}" did not become ready within the polling window. It may still be starting up.`,
        );
        serverUrl = `http://${name}-proxy-svc.${namespace}.svc.cluster.local:8080`;
      }

      // Optionally create an HTTPRoute so the server is reachable through the
      // shared Traefik gateway at `/<path>/mcp`. The ToolHive operator creates
      // a Service named `mcp-<name>-proxy` on port 8080 for each MCPServer, so
      // the route mirrors the pattern used by existing demo manifests.
      let resolvedIngressPath: string | undefined;
      if (exposeViaIngress) {
        const rawPath = ingressPath || `/${name}`;
        resolvedIngressPath = rawPath.startsWith('/') ? rawPath : `/${rawPath}`;
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

          // Resolve the Traefik gateway IP so the log prints the URL the user
          // will actually hit from outside the cluster.
          const hostname = await resolveTraefikHostname(customObjectsApi);
          if (hostname) {
            const ingressUrl = `http://${hostname}${resolvedIngressPath}/mcp`;
            ctx.logger.info(
              `MCPServer "${name}" is reachable at ${ingressUrl}`,
            );
            ctx.output('ingressUrl', ingressUrl);
          } else {
            ctx.logger.warn(
              `HTTPRoute "${name}-mcp-route" created, but could not resolve Traefik gateway hostname — check "kubectl get gateway -n traefik traefik-gateway".`,
            );
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
