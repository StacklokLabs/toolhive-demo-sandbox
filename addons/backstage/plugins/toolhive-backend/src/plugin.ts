import {
  coreServices,
  createBackendPlugin,
} from '@backstage/backend-plugin-api';
import { createRouter } from './router';

/**
 * The ToolHive backend plugin.
 *
 * Provides REST API endpoints for managing ToolHive MCPServer
 * custom resources in Kubernetes.
 *
 * @public
 */
export const toolhivePlugin = createBackendPlugin({
  pluginId: 'toolhive',
  register(env) {
    env.registerInit({
      deps: {
        logger: coreServices.logger,
        config: coreServices.rootConfig,
        httpRouter: coreServices.httpRouter,
        httpAuth: coreServices.httpAuth,
      },
      async init({ logger, config, httpRouter, httpAuth }) {
        httpRouter.use(
          await createRouter({
            logger,
            config,
            httpAuth,
          }),
        );
        httpRouter.addAuthPolicy({
          path: '/servers',
          allow: 'unauthenticated',
        });
        httpRouter.addAuthPolicy({
          path: '/servers/:namespace/:name',
          allow: 'unauthenticated',
        });
        httpRouter.addAuthPolicy({
          path: '/registry/servers',
          allow: 'unauthenticated',
        });
      },
    });
  },
});
