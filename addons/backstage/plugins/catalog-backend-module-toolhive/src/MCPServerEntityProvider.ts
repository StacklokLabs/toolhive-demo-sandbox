import {
  EntityProvider,
  EntityProviderConnection,
} from '@backstage/plugin-catalog-node';
import * as k8s from '@kubernetes/client-node';
import { LoggerService } from '@backstage/backend-plugin-api';

const API_GROUP = 'toolhive.stacklok.dev';
const API_VERSION = 'v1beta1';
const PLURAL = 'mcpservers';

/**
 * An entity provider that syncs ToolHive MCPServer custom resources
 * from Kubernetes into the Backstage catalog as Resource entities.
 */
export class MCPServerEntityProvider implements EntityProvider {
  private connection?: EntityProviderConnection;
  private readonly customObjectsApi: k8s.CustomObjectsApi;
  private readonly logger: LoggerService;

  constructor(logger: LoggerService) {
    this.logger = logger;
    const kc = new k8s.KubeConfig();
    kc.loadFromDefault();
    this.customObjectsApi = kc.makeApiClient(k8s.CustomObjectsApi);
  }

  getProviderName(): string {
    return 'toolhive-mcpserver-provider';
  }

  async connect(connection: EntityProviderConnection): Promise<void> {
    this.connection = connection;
  }

  async run(): Promise<void> {
    if (!this.connection) {
      throw new Error('MCPServerEntityProvider is not connected');
    }

    try {
      // List all MCPServer CRs across all namespaces
      const response = await this.customObjectsApi.listClusterCustomObject({
        group: API_GROUP,
        version: API_VERSION,
        plural: PLURAL,
      });

      const list = response as unknown as { items?: Array<MCPServerCR> };
      const items = list.items || [];

      // Convert each MCPServer CR to a Backstage Resource entity
      const entities = items.map((item: MCPServerCR) => {
        const namespace = item.metadata?.namespace || 'default';
        const name = item.metadata?.name || 'unknown';

        return {
          entity: {
            apiVersion: 'backstage.io/v1alpha1',
            kind: 'Resource',
            metadata: {
              name: `mcpserver-${namespace}-${name}`,
              namespace: 'default',
              annotations: {
                'backstage.io/managed-by-location': `toolhive-mcpserver-provider:${namespace}/${name}`,
                'backstage.io/managed-by-origin-location': `toolhive-mcpserver-provider:${namespace}/${name}`,
                'toolhive.stacklok.dev/k8s-namespace': namespace,
                'toolhive.stacklok.dev/k8s-name': name,
                'toolhive.stacklok.dev/phase':
                  item.status?.phase || 'Unknown',
                'toolhive.stacklok.dev/url': item.status?.url || '',
                'toolhive.stacklok.dev/image': item.spec?.image || '',
              },
              labels: {
                'toolhive.stacklok.dev/transport':
                  item.spec?.transport || 'stdio',
                'toolhive.stacklok.dev/managed': 'true',
              },
            },
            spec: {
              type: 'mcp-server',
              owner: 'platform-team',
              lifecycle:
                item.status?.phase === 'Ready' ? 'production' : 'experimental',
            },
          },
          locationKey: `toolhive-mcpserver-provider:${namespace}/${name}`,
        };
      });

      await this.connection.applyMutation({
        type: 'full',
        entities,
      });

      this.logger.info(
        `Synced ${entities.length} MCPServer entities to catalog`,
      );
    } catch (error) {
      this.logger.error('Failed to sync MCPServer entities to catalog', {
        error: String(error),
      });
      throw error;
    }
  }
}

/**
 * Minimal type definition for a MCPServer custom resource as returned
 * from the Kubernetes API. Only the fields we need for catalog sync
 * are included here.
 */
interface MCPServerCR {
  metadata?: {
    name?: string;
    namespace?: string;
  };
  spec?: {
    image?: string;
    transport?: string;
  };
  status?: {
    phase?: string;
    url?: string;
    message?: string;
    readyReplicas?: number;
  };
}
