import {
  createApiRef,
  DiscoveryApi,
  FetchApi,
} from '@backstage/frontend-plugin-api';
import {
  MCPServer,
  MCPServerListResponse,
  RegistryServerEntry,
  RegistryServersResponse,
} from './types';

/**
 * API interface for the ToolHive frontend plugin.
 */
export interface ToolhiveApi {
  listServers(namespace?: string): Promise<MCPServer[]>;
  getServer(namespace: string, name: string): Promise<MCPServer>;
  deleteServer(namespace: string, name: string): Promise<void>;
  listRegistryServers(search?: string, latestOnly?: boolean): Promise<RegistryServerEntry[]>;
}

/**
 * ApiRef for the ToolHive API.
 */
export const toolhiveApiRef = createApiRef<ToolhiveApi>({
  id: 'plugin.toolhive.api',
});

/**
 * Client implementation that calls the ToolHive backend plugin REST API.
 */
export class ToolhiveClient implements ToolhiveApi {
  private readonly discoveryApi: DiscoveryApi;
  private readonly fetchApi: FetchApi;

  constructor(options: { discoveryApi: DiscoveryApi; fetchApi: FetchApi }) {
    this.discoveryApi = options.discoveryApi;
    this.fetchApi = options.fetchApi;
  }

  private async getBaseUrl(): Promise<string> {
    return await this.discoveryApi.getBaseUrl('toolhive');
  }

  async listServers(namespace?: string): Promise<MCPServer[]> {
    const baseUrl = await this.getBaseUrl();
    const query = namespace
      ? `?${new URLSearchParams({ namespace }).toString()}`
      : '';
    const response = await this.fetchApi.fetch(`${baseUrl}/servers${query}`);

    if (!response.ok) {
      throw new Error(
        `Failed to list MCP servers: ${response.status} ${response.statusText}`,
      );
    }

    const data: MCPServerListResponse = await response.json();
    return data.items;
  }

  async getServer(namespace: string, name: string): Promise<MCPServer> {
    const baseUrl = await this.getBaseUrl();
    const response = await this.fetchApi.fetch(
      `${baseUrl}/servers/${encodeURIComponent(namespace)}/${encodeURIComponent(name)}`,
    );

    if (!response.ok) {
      throw new Error(
        `Failed to get MCP server '${name}': ${response.status} ${response.statusText}`,
      );
    }

    return await response.json();
  }

  async deleteServer(namespace: string, name: string): Promise<void> {
    const baseUrl = await this.getBaseUrl();
    const response = await this.fetchApi.fetch(
      `${baseUrl}/servers/${encodeURIComponent(namespace)}/${encodeURIComponent(name)}`,
      { method: 'DELETE' },
    );

    if (!response.ok) {
      throw new Error(
        `Failed to delete MCP server '${name}': ${response.status} ${response.statusText}`,
      );
    }
  }

  async listRegistryServers(
    search?: string,
    latestOnly: boolean = true,
  ): Promise<RegistryServerEntry[]> {
    const baseUrl = await this.getBaseUrl();
    const params = new URLSearchParams({ limit: '200' });
    if (search) {
      params.set('search', search);
    }
    if (latestOnly) {
      params.set('version', 'latest');
    }
    const response = await this.fetchApi.fetch(
      `${baseUrl}/registry/servers?${params.toString()}`,
    );

    if (!response.ok) {
      throw new Error(
        `Failed to list registry servers: ${response.status} ${response.statusText}`,
      );
    }

    const data: RegistryServersResponse = await response.json();
    return data.servers ?? [];
  }
}
