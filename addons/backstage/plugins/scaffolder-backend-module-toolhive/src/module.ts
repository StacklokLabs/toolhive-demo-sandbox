import { createBackendModule } from '@backstage/backend-plugin-api';
import { coreServices } from '@backstage/backend-plugin-api';
import { scaffolderActionsExtensionPoint } from '@backstage/plugin-scaffolder-node';
import { createDeployMCPServerAction } from './actions/deployMCPServer';
import { createDeployFromRegistryAction } from './actions/deployFromRegistry';

/**
 * Backend module that registers the toolhive scaffolder actions:
 * - toolhive:deploy:mcpserver  (manual image/transport)
 * - toolhive:registry:deploy   (look up from registry, then deploy)
 */
export const scaffolderModuleToolhive = createBackendModule({
  pluginId: 'scaffolder',
  moduleId: 'toolhive',
  register(env) {
    env.registerInit({
      deps: {
        scaffolderActions: scaffolderActionsExtensionPoint,
        config: coreServices.rootConfig,
      },
      async init({ scaffolderActions, config }) {
        const registryUrl = config.getOptionalString('toolhive.registryUrl');
        scaffolderActions.addActions(
          createDeployMCPServerAction(),
          createDeployFromRegistryAction({
            registryUrl: registryUrl || undefined,
          }),
        );
      },
    });
  },
});
