import { createRouteRef } from '@backstage/frontend-plugin-api';

/**
 * Route ref for the MCP Server list page (/toolhive).
 */
export const rootRouteRef = createRouteRef();

/**
 * Route ref for the MCP Server detail page (/toolhive/:namespace/:name).
 */
export const serverDetailRouteRef = createRouteRef({
  params: ['namespace', 'name'],
});

/**
 * Route ref for the MCP Server Registry page (/toolhive/registry).
 */
export const registryRouteRef = createRouteRef();
