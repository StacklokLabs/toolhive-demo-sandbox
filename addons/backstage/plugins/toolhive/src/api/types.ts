/**
 * Frontend-side type definitions for ToolHive MCPServer resources.
 *
 * These mirror the backend types but are maintained separately
 * to decouple the frontend from backend internals.
 */

export interface MCPServerSpec {
  image: string;
  transport?: 'stdio' | 'streamable-http' | 'sse';
  proxyMode?: 'sse' | 'streamable-http';
  proxyPort?: number;
  mcpPort?: number;
  args?: string[];
  env?: Array<{ name: string; value: string }>;
  secrets?: Array<{ name: string; key: string; targetEnvName: string }>;
  resources?: {
    limits?: Record<string, string>;
    requests?: Record<string, string>;
  };
  permissionProfile?: { type: 'builtin' | 'configmap'; name: string };
  replicas?: number;
  backendReplicas?: number;
}

export interface MCPServerCondition {
  type: string;
  status: string;
  reason?: string;
  message?: string;
  lastTransitionTime?: string;
}

export interface MCPServerStatus {
  phase?: 'Pending' | 'Ready' | 'Failed' | 'Terminating' | 'Stopped';
  url?: string;
  message?: string;
  readyReplicas?: number;
  conditions?: MCPServerCondition[];
}

export interface MCPServer {
  apiVersion: string;
  kind: string;
  metadata: {
    name: string;
    namespace: string;
    creationTimestamp?: string;
    uid?: string;
    labels?: Record<string, string>;
    annotations?: Record<string, string>;
  };
  spec: MCPServerSpec;
  status?: MCPServerStatus;
  ingress?: MCPServerIngress;
}

export interface MCPServerIngress {
  hostname: string;
  path: string;
  url: string;
}

export interface MCPServerListResponse {
  items: MCPServer[];
}

/**
 * Types for the ToolHive Registry Server API responses.
 */

export interface RegistryEnvironmentVariable {
  name: string;
  description?: string;
  isRequired?: boolean;
  isSecret?: boolean;
}

export interface RegistryPackage {
  registryType: string;
  identifier: string;
  transport: {
    type: string;
  };
  environmentVariables?: RegistryEnvironmentVariable[];
}

export interface RegistryServerEntry {
  server: {
    name: string;
    description?: string;
    title?: string;
    version?: string;
    repository?: {
      url: string;
      source?: string;
    };
    packages: RegistryPackage[];
    _meta?: Record<string, unknown>;
  };
}

export interface RegistryServersResponse {
  servers: RegistryServerEntry[];
  metadata?: Record<string, unknown>;
}
