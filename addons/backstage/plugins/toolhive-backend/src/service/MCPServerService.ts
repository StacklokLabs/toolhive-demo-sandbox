import * as k8s from '@kubernetes/client-node';
import { LoggerService } from '@backstage/backend-plugin-api';
import {
  MCPServer,
  MCPServerIngress,
  MCPServerList,
  CreateMCPServerRequest,
} from '../types';

const API_GROUP = 'toolhive.stacklok.dev';
const API_VERSION = 'v1beta1';
const PLURAL = 'mcpservers';
const DEFAULT_NAMESPACE = 'default';

const GATEWAY_API_GROUP = 'gateway.networking.k8s.io';
const GATEWAY_API_VERSION = 'v1';
const HTTPROUTE_PLURAL = 'httproutes';
const GATEWAY_PLURAL = 'gateways';
const TRAEFIK_GATEWAY_NAME = 'traefik-gateway';
const TRAEFIK_GATEWAY_NAMESPACE = 'traefik';
const MCPSERVER_LABEL = 'toolhive.stacklok.dev/mcpserver';

export class MCPServerService {
  private readonly customObjectsApi: k8s.CustomObjectsApi;
  private readonly logger: LoggerService;

  constructor(logger: LoggerService) {
    this.logger = logger;
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
   * with the resolved Traefik gateway hostname, and returns the public URL
   * the server is reachable at. Returns undefined if no matching route exists
   * or the gateway IP cannot be resolved.
   */
  private async resolveIngress(
    name: string,
    namespace: string,
  ): Promise<MCPServerIngress | undefined> {
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
      const hostname = await this.resolveTraefikHostname();
      if (!hostname) return undefined;

      return {
        hostname,
        path,
        url: `http://${hostname}${path}/mcp`,
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

  /**
   * Resolves the shared Traefik gateway's external IP into a traefik.me
   * hostname (e.g. `172.20.0.3` → `mcp-172-20-0-3.traefik.me`).
   */
  private async resolveTraefikHostname(): Promise<string | undefined> {
    try {
      const gateway = (await this.customObjectsApi.getNamespacedCustomObject({
        group: GATEWAY_API_GROUP,
        version: GATEWAY_API_VERSION,
        namespace: TRAEFIK_GATEWAY_NAMESPACE,
        plural: GATEWAY_PLURAL,
        name: TRAEFIK_GATEWAY_NAME,
      })) as unknown as { status?: { addresses?: Array<{ value?: string }> } };

      const ip = gateway?.status?.addresses?.[0]?.value;
      if (!ip) return undefined;
      return `mcp-${ip.replace(/\./g, '-')}.traefik.me`;
    } catch (error) {
      this.logger.warn('Failed to resolve Traefik gateway hostname', {
        error: String(error),
      });
      return undefined;
    }
  }

  async create(request: CreateMCPServerRequest): Promise<MCPServer> {
    const namespace = request.namespace || DEFAULT_NAMESPACE;

    const manifest: MCPServer = {
      apiVersion: `${API_GROUP}/${API_VERSION}`,
      kind: 'MCPServer',
      metadata: {
        name: request.name,
        namespace,
      },
      spec: {
        image: request.image,
        ...(request.transport && { transport: request.transport }),
        ...(request.port && { proxyPort: request.port }),
        ...(request.env && request.env.length > 0 && { env: request.env }),
        ...(request.args && request.args.length > 0 && { args: request.args }),
        ...(request.replicas && { replicas: request.replicas }),
      },
    };

    try {
      const response = await this.customObjectsApi.createNamespacedCustomObject({
        group: API_GROUP,
        version: API_VERSION,
        namespace,
        plural: PLURAL,
        body: manifest,
      });
      this.logger.info('Created MCPServer', { name: request.name, namespace });
      return response as unknown as MCPServer;
    } catch (error) {
      this.logger.error('Failed to create MCPServer', {
        error: String(error),
        name: request.name,
        namespace,
      });
      throw error;
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
  }

  async getStatus(name: string, namespace: string = DEFAULT_NAMESPACE): Promise<MCPServer> {
    // The status is included in the regular get response
    return this.get(name, namespace);
  }
}
