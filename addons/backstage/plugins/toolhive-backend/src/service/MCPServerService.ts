import * as k8s from '@kubernetes/client-node';
import { LoggerService } from '@backstage/backend-plugin-api';
import { MCPServer, MCPServerIngress, MCPServerList } from '../types';

const API_GROUP = 'toolhive.stacklok.dev';
const API_VERSION = 'v1beta1';
const PLURAL = 'mcpservers';
const DEFAULT_NAMESPACE = 'mcp-workloads';

const GATEWAY_API_GROUP = 'gateway.networking.k8s.io';
const GATEWAY_API_VERSION = 'v1';
const HTTPROUTE_PLURAL = 'httproutes';
const MCPSERVER_LABEL = 'toolhive.stacklok.dev/mcpserver';

export class MCPServerService {
  private readonly customObjectsApi: k8s.CustomObjectsApi;
  private readonly logger: LoggerService;
  /**
   * Public base URL the MCP servers are reachable at (e.g.
   * `http://mcp-172-19-0-3.sslip.io`), injected from `toolhive.mcpHostname`.
   * Used to build ingress URLs without an in-cluster gateway lookup.
   */
  private readonly mcpHostname?: string;

  constructor(logger: LoggerService, mcpHostname?: string) {
    this.logger = logger;
    this.mcpHostname = mcpHostname;
    const kc = new k8s.KubeConfig();
    kc.loadFromDefault();
    this.customObjectsApi = kc.makeApiClient(k8s.CustomObjectsApi);
  }

  async list(namespace?: string): Promise<MCPServer[]> {
    try {
      let response;
      if (namespace) {
        response = await this.customObjectsApi.listNamespacedCustomObject({
          group: API_GROUP,
          version: API_VERSION,
          namespace,
          plural: PLURAL,
        });
      } else {
        response = await this.customObjectsApi.listClusterCustomObject({
          group: API_GROUP,
          version: API_VERSION,
          plural: PLURAL,
        });
      }
      const list = response as unknown as MCPServerList;
      return list.items || [];
    } catch (error) {
      this.logger.error('Failed to list MCPServers', {
        error: String(error),
        namespace: namespace || 'all',
      });
      throw error;
    }
  }

  async get(name: string, namespace: string = DEFAULT_NAMESPACE): Promise<MCPServer> {
    try {
      const response = await this.customObjectsApi.getNamespacedCustomObject({
        group: API_GROUP,
        version: API_VERSION,
        namespace,
        plural: PLURAL,
        name,
      });
      const server = response as unknown as MCPServer;
      const ingress = await this.resolveIngress(name, namespace);
      if (ingress) {
        server.ingress = ingress;
      }
      return server;
    } catch (error) {
      this.logger.error('Failed to get MCPServer', {
        error: String(error),
        name,
        namespace,
      });
      throw error;
    }
  }

  /**
   * Looks up an HTTPRoute in the MCPServer's namespace labeled with
   * `toolhive.stacklok.dev/mcpserver=<name>`, combines its first path-prefix
   * with the configured public MCP hostname, and returns the public URL the
   * server is reachable at. Returns undefined if no matching route exists or
   * no public hostname is configured.
   */
  private async resolveIngress(
    name: string,
    namespace: string,
  ): Promise<MCPServerIngress | undefined> {
    if (!this.mcpHostname) return undefined;

    try {
      const list = (await this.customObjectsApi.listNamespacedCustomObject({
        group: GATEWAY_API_GROUP,
        version: GATEWAY_API_VERSION,
        namespace,
        plural: HTTPROUTE_PLURAL,
        labelSelector: `${MCPSERVER_LABEL}=${name}`,
      })) as unknown as { items: any[] };

      const route = list?.items?.[0];
      if (!route) return undefined;

      const path =
        route?.spec?.rules?.[0]?.matches?.[0]?.path?.value ?? `/${name}`;
      // mcpHostname carries a scheme (e.g. `http://mcp-<ip>.sslip.io`); the
      // ingress `hostname` field is the bare host for display.
      const hostname = this.mcpHostname.replace(/^https?:\/\//, '');

      return {
        hostname,
        path,
        url: `${this.mcpHostname}${path}/mcp`,
      };
    } catch (error) {
      this.logger.warn('Failed to resolve ingress for MCPServer', {
        error: String(error),
        name,
        namespace,
      });
      return undefined;
    }
  }

  async delete(name: string, namespace: string = DEFAULT_NAMESPACE): Promise<void> {
    try {
      await this.customObjectsApi.deleteNamespacedCustomObject({
        group: API_GROUP,
        version: API_VERSION,
        namespace,
        plural: PLURAL,
        name,
      });
      this.logger.info('Deleted MCPServer', { name, namespace });
    } catch (error) {
      this.logger.error('Failed to delete MCPServer', {
        error: String(error),
        name,
        namespace,
      });
      throw error;
    }

    // Best-effort: delete any HTTPRoutes labeled with this MCPServer's name.
    try {
      const routes = (await this.customObjectsApi.listNamespacedCustomObject({
        group: GATEWAY_API_GROUP,
        version: GATEWAY_API_VERSION,
        namespace,
        plural: HTTPROUTE_PLURAL,
        labelSelector: `${MCPSERVER_LABEL}=${name}`,
      })) as unknown as { items: Array<{ metadata: { name: string } }> };

      for (const route of routes.items ?? []) {
        await this.customObjectsApi.deleteNamespacedCustomObject({
          group: GATEWAY_API_GROUP,
          version: GATEWAY_API_VERSION,
          namespace,
          plural: HTTPROUTE_PLURAL,
          name: route.metadata.name,
        });
        this.logger.info('Deleted HTTPRoute', { name: route.metadata.name, namespace });
      }
    } catch (error) {
      this.logger.warn('Failed to clean up HTTPRoutes for MCPServer', {
        error: String(error),
        name,
        namespace,
      });
    }
  }
}
