import * as k8s from '@kubernetes/client-node';

export const API_GROUP = 'toolhive.stacklok.dev';
export const API_VERSION = 'v1beta1';
export const MCPSERVER_PLURAL = 'mcpservers';

/**
 * Minimal logger shape shared by the scaffolder action `ctx.logger`.
 */
export interface ActionLogger {
  info(message: string): void;
  warn(message: string): void;
  error(message: string): void;
}

/**
 * Loads the default kubeconfig (in-cluster service account when running in a
 * pod) and returns a CustomObjects API client.
 */
export function createCustomObjectsApi(): k8s.CustomObjectsApi {
  const kc = new k8s.KubeConfig();
  kc.loadFromDefault();
  return kc.makeApiClient(k8s.CustomObjectsApi);
}

/**
 * Creates an MCPServer custom resource. Throws a descriptive error if the
 * Kubernetes API rejects the manifest.
 */
export async function createMCPServer(
  api: k8s.CustomObjectsApi,
  manifest: object,
  name: string,
  namespace: string,
  logger: ActionLogger,
): Promise<void> {
  logger.info(`Creating MCPServer CR "${name}" in namespace "${namespace}"`);
  try {
    await api.createNamespacedCustomObject({
      group: API_GROUP,
      version: API_VERSION,
      namespace,
      plural: MCPSERVER_PLURAL,
      body: manifest,
    });
  } catch (error: unknown) {
    const message = error instanceof Error ? error.message : String(error);
    logger.error(`Failed to create MCPServer: ${message}`);
    throw new Error(`Failed to create MCPServer "${name}": ${message}`);
  }
}

/**
 * Polls an MCPServer's status for a ready URL (up to 30 seconds). Returns the
 * reported status URL, or a cluster-internal fallback URL if the server hasn't
 * reported one within the polling window. Throws if the server enters the
 * Failed phase.
 */
export async function waitForServerUrl(
  api: k8s.CustomObjectsApi,
  name: string,
  namespace: string,
  logger: ActionLogger,
): Promise<string> {
  const pollInterval = 2000;
  const maxAttempts = 15;

  logger.info(`MCPServer CR "${name}" created, waiting for status...`);

  for (let attempt = 0; attempt < maxAttempts; attempt++) {
    try {
      const response = (await api.getNamespacedCustomObject({
        group: API_GROUP,
        version: API_VERSION,
        namespace,
        plural: MCPSERVER_PLURAL,
        name,
      })) as { status?: { phase?: string; url?: string } };

      const status = response?.status;
      if (status?.url) {
        logger.info(`MCPServer "${name}" is ready at ${status.url}`);
        return status.url;
      }

      const phase = status?.phase || 'Unknown';
      logger.info(
        `MCPServer "${name}" phase: ${phase} (attempt ${attempt + 1}/${maxAttempts})`,
      );

      if (phase === 'Failed') {
        throw new Error(`MCPServer "${name}" entered Failed phase`);
      }
    } catch (error: unknown) {
      if (error instanceof Error && error.message.includes('Failed phase')) {
        throw error;
      }
      logger.warn(
        `Failed to get MCPServer status (attempt ${attempt + 1}): ${
          error instanceof Error ? error.message : String(error)
        }`,
      );
    }

    await new Promise(resolve => setTimeout(resolve, pollInterval));
  }

  logger.warn(
    `MCPServer "${name}" did not become ready within the polling window. It may still be starting up.`,
  );
  // The ToolHive operator creates a Service named `mcp-<name>-proxy` on
  // port 8080 for each MCPServer.
  return `http://mcp-${name}-proxy.${namespace}.svc.cluster.local:8080`;
}
