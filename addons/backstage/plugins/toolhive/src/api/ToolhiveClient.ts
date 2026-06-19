import {
  createApiRef,
  DiscoveryApi,
  FetchApi,
} from '@backstage/frontend-plugin-api';
import {
  MCPServer,
  MCPServerListResponse,
  CreateMCPServerRequest,
  RegistryServerEntry,
  RegistryServersResponse,
} from './types';

/**
 * API interface for the ToolHive frontend plugin.
 */
export interface ToolhiveApi {
  listServers(namespace?: string): Promise<MCPServer[]>;
  getServer(namespace: string, name: string): Promise<MCPServer>;
  createServer(request: CreateMCPServerRequest): Promise<MCPServer>;
  deleteServer(namespace: string, name: string): Promise<void>;
  listRegistryServers(search?: string): Promise<RegistryServerEntry[]>;
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

  async createServer(request: CreateMCPServerRequest): Promise<MCPServer> {
    const baseUrl = await this.getBaseUrl();
    const response = await this.fetchApi.fetch(`${baseUrl}/servers`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify(request),
    });

    if (!response.ok) {
      throw new Error(
        `Failed to create MCP server: ${response.status} ${response.statusText}`,
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
  ): Promise<RegistryServerEntry[]> {
    const baseUrl = await this.getBaseUrl();
    const params = new URLSearchParams({ limit: '200' });
    if (search) {
      params.set('search', search);
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
