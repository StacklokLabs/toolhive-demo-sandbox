import React from 'react';
import {
  createFrontendPlugin,
  createApiFactory,
  discoveryApiRef,
  fetchApiRef,
  PageBlueprint,
  ApiBlueprint,
} from '@backstage/frontend-plugin-api';
import { toolhiveApiRef, ToolhiveClient } from './api';
import { rootRouteRef, serverDetailRouteRef, registryRouteRef } from './routes';
import StorageIcon from '@material-ui/icons/Storage';
import CategoryIcon from '@material-ui/icons/Category';

/**
 * API extension: registers the ToolHive API client factory.
 */
const toolhiveApi = ApiBlueprint.make({
  params: defineParams =>
    defineParams(
      createApiFactory({
        api: toolhiveApiRef,
        deps: { discoveryApi: discoveryApiRef, fetchApi: fetchApiRef },
        factory: ({ discoveryApi, fetchApi }) =>
          new ToolhiveClient({ discoveryApi, fetchApi }),
      }),
    ),
});

/**
 * Page extension: MCP Server list page at /toolhive.
 */
const toolhiveListPage = PageBlueprint.make({
  params: {
    path: '/toolhive',
    routeRef: rootRouteRef,
    title: 'MCP Servers',
    icon: React.createElement(StorageIcon),
    loader: () =>
      import('./components/MCPServerListPage').then(m =>
        React.createElement(m.MCPServerListPage),
      ),
  },
});

/**
 * Page extension: MCP Server detail page at /toolhive/:namespace/:name.
 */
const toolhiveDetailPage = PageBlueprint.make({
  name: 'detail',
  params: {
    path: '/toolhive/:namespace/:name',
    routeRef: serverDetailRouteRef,
    loader: () =>
      import('./components/MCPServerDetailPage').then(m =>
        React.createElement(m.MCPServerDetailPage),
      ),
  },
});

/**
 * Page extension: MCP Server Registry page at /toolhive/registry.
 */
const toolhiveRegistryPage = PageBlueprint.make({
  name: 'registry',
  params: {
    path: '/toolhive/registry',
    routeRef: registryRouteRef,
    title: 'MCP Registry',
    icon: React.createElement(CategoryIcon),
    loader: () =>
      import('./components/RegistryPage').then(m =>
        React.createElement(m.RegistryPage),
      ),
  },
});

/**
 * The ToolHive frontend plugin.
 */
export default createFrontendPlugin({
  pluginId: 'toolhive',
  extensions: [toolhiveApi, toolhiveListPage, toolhiveDetailPage, toolhiveRegistryPage],
  routes: {
    root: rootRouteRef,
    serverDetail: serverDetailRouteRef,
    registry: registryRouteRef,
  },
});
