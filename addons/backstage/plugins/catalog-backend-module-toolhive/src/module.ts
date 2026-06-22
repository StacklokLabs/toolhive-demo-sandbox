import {
  createBackendModule,
  coreServices,
} from '@backstage/backend-plugin-api';
import { catalogProcessingExtensionPoint } from '@backstage/plugin-catalog-node';
import { MCPServerEntityProvider } from './MCPServerEntityProvider';

/**
 * A backend module that registers the MCPServerEntityProvider with the catalog.
 * This periodically syncs ToolHive MCPServer custom resources from Kubernetes
 * into the Backstage catalog as Resource entities of type 'mcp-server'.
 */
export const catalogModuleToolhive = createBackendModule({
  pluginId: 'catalog',
  moduleId: 'toolhive-mcpserver-provider',
  register(env) {
    env.registerInit({
      deps: {
        catalog: catalogProcessingExtensionPoint,
        logger: coreServices.logger,
        scheduler: coreServices.scheduler,
      },
      async init({ catalog, logger, scheduler }) {
        const provider = new MCPServerEntityProvider(logger);
        catalog.addEntityProvider(provider);

        await scheduler.scheduleTask({
          id: 'toolhive-mcpserver-provider-refresh',
          frequency: { seconds: 30 },
          timeout: { minutes: 5 },
          fn: async () => {
            await provider.run();
          },
        });
      },
    });
  },
});
