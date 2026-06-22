/**
 * The ToolHive frontend plugin.
 *
 * @packageDocumentation
 */

export { default } from './plugin';
export { toolhiveApiRef } from './api';
export type { ToolhiveApi } from './api';
export type {
  MCPServer,
  MCPServerSpec,
  MCPServerStatus,
} from './api';
export { rootRouteRef, serverDetailRouteRef, registryRouteRef } from './routes';
