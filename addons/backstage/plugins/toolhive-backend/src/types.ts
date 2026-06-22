/**
 * TypeScript types matching the ToolHive MCPServer CRD.
 *
 * CRD API group: toolhive.stacklok.dev
 * CRD version: v1beta1
 * CRD plural: mcpservers
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

export interface MCPServerStatus {
  phase?: 'Pending' | 'Ready' | 'Failed' | 'Terminating' | 'Stopped';
  url?: string;
  message?: string;
  readyReplicas?: number;
  conditions?: Array<{
    type: string;
    status: string;
    reason?: string;
    message?: string;
    lastTransitionTime?: string;
  }>;
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
  /**
   * Resolved ingress info, populated by the backend when an HTTPRoute on the
   * shared Traefik gateway is associated with this MCPServer (matched via the
   * `toolhive.stacklok.dev/mcpserver=<name>` label).
   */
  ingress?: MCPServerIngress;
}

export interface MCPServerIngress {
  hostname: string;
  path: string;
  url: string;
}

export interface MCPServerList {
  apiVersion: string;
  kind: string;
  metadata: {
    resourceVersion?: string;
  };
  items: MCPServer[];
}
