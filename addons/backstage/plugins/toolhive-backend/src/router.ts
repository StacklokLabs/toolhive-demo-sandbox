import {
  HttpAuthService,
  LoggerService,
} from '@backstage/backend-plugin-api';
import { Config } from '@backstage/config';
import { InputError, NotFoundError } from '@backstage/errors';
import { z } from 'zod/v3';
import express from 'express';
import Router from 'express-promise-router';
import { MCPServerService } from './service/MCPServerService';

export interface RouterOptions {
  logger: LoggerService;
  config: Config;
  httpAuth: HttpAuthService;
}

export async function createRouter(
  options: RouterOptions,
): Promise<express.Router> {
  const { logger, httpAuth } = options;
  const mcpServerService = new MCPServerService(logger);

  const router = Router();
  router.use(express.json());

  const createServerSchema = z.object({
    name: z.string().min(1),
    namespace: z.string().optional(),
    image: z.string().min(1),
    transport: z.enum(['stdio', 'streamable-http', 'sse']).optional(),
    port: z.number().int().positive().optional(),
    env: z
      .array(z.object({ name: z.string(), value: z.string() }))
      .optional(),
    args: z.array(z.string()).optional(),
    replicas: z.number().int().positive().optional(),
  });

  // GET /servers - List all MCPServer CRs
  router.get('/servers', async (req, res) => {
    await httpAuth.credentials(req, { allow: ['user'], allowLimitedAccess: true }).catch(() => {});

    const namespace =
      typeof req.query.namespace === 'string'
        ? req.query.namespace
        : undefined;

    try {
      const servers = await mcpServerService.list(namespace);
      res.json({ items: servers });
    } catch (error) {
      const statusCode = getK8sErrorStatus(error);
      logger.error('Failed to list MCPServers', { error: String(error) });
      res.status(statusCode).json({ error: 'Failed to list MCPServers' });
    }
  });

  // GET /servers/:namespace/:name - Get single MCPServer
  router.get('/servers/:namespace/:name', async (req, res) => {
    await httpAuth.credentials(req, { allow: ['user'], allowLimitedAccess: true }).catch(() => {});

    const { namespace, name } = req.params;

    try {
      const server = await mcpServerService.get(name, namespace);
      res.json(server);
    } catch (error) {
      const statusCode = getK8sErrorStatus(error);
      if (statusCode === 404) {
        throw new NotFoundError(
          `MCPServer '${name}' not found in namespace '${namespace}'`,
        );
      }
      logger.error('Failed to get MCPServer', { error: String(error) });
      res.status(statusCode).json({ error: 'Failed to get MCPServer' });
    }
  });

  // POST /servers - Create MCPServer CR
  router.post('/servers', async (req, res) => {
    await httpAuth.credentials(req, { allow: ['user'], allowLimitedAccess: true }).catch(() => {});

    const parsed = createServerSchema.safeParse(req.body);
    if (!parsed.success) {
      throw new InputError(parsed.error.toString());
    }

    try {
      const server = await mcpServerService.create(parsed.data);
      res.status(201).json(server);
    } catch (error) {
      const statusCode = getK8sErrorStatus(error);
      logger.error('Failed to create MCPServer', { error: String(error) });
      res.status(statusCode).json({ error: 'Failed to create MCPServer' });
    }
  });

  // DELETE /servers/:namespace/:name - Delete MCPServer CR
  router.delete('/servers/:namespace/:name', async (req, res) => {
    await httpAuth.credentials(req, { allow: ['user'], allowLimitedAccess: true }).catch(() => {});

    const { namespace, name } = req.params;

    try {
      await mcpServerService.delete(name, namespace);
      res.status(204).send();
    } catch (error) {
      const statusCode = getK8sErrorStatus(error);
      if (statusCode === 404) {
        throw new NotFoundError(
          `MCPServer '${name}' not found in namespace '${namespace}'`,
        );
      }
      logger.error('Failed to delete MCPServer', { error: String(error) });
      res.status(statusCode).json({ error: 'Failed to delete MCPServer' });
    }
  });

  // GET /registry/servers - Proxy to the ToolHive Registry Server
  router.get('/registry/servers', async (req, res) => {
    try {
      const registryUrl =
        options.config.getOptionalString('toolhive.registryUrl') ||
        'http://toolhive-registry-api.toolhive-system.svc.cluster.local:8080';
      const registryName =
        options.config.getOptionalString('toolhive.registryName') || 'default';
      const limit = req.query.limit || '100';
      const search = req.query.search
        ? `&search=${encodeURIComponent(req.query.search as string)}`
        : '';

      const response = await fetch(
        `${registryUrl}/registry/${registryName}/v0.1/servers?limit=${limit}${search}`,
      );

      if (!response.ok) {
        throw new Error(`Registry returned ${response.status}`);
      }

      const data = await response.json();

      // Drop K8s auto-discovered entries — the registry's `k8s` source publishes
      // one entry per running MCPServer/MCPRemoteProxy, which mixes "running in
      // this cluster" with "installable from the metadata registry". The Registry
      // page is meant to show only catalog (git-sourced) entries available to
      // deploy. K8s-sourced entries carry a `metadata.kubernetes` block under
      // _meta.publisher-provided.*.*; metadata entries do not.
      if (Array.isArray(data?.servers)) {
        data.servers = data.servers.filter((entry: any) => {
          const pp = entry?.server?._meta?.[
            'io.modelcontextprotocol.registry/publisher-provided'
          ];
          if (!pp || typeof pp !== 'object') return true;
          for (const publisher of Object.values(pp)) {
            if (!publisher || typeof publisher !== 'object') continue;
            for (const info of Object.values(publisher as Record<string, any>)) {
              if (info?.metadata?.kubernetes) return false;
            }
          }
          return true;
        });
      }

      res.json(data);
    } catch (error) {
      logger.error('Failed to fetch from registry', {
        error: String(error),
      });
      res
        .status(502)
        .json({ error: 'Failed to fetch MCP servers from registry' });
    }
  });

  return router;
}

/**
 * Extract HTTP status code from a Kubernetes API error.
 */
function getK8sErrorStatus(error: unknown): number {
  if (
    error &&
    typeof error === 'object' &&
    'statusCode' in error &&
    typeof (error as Record<string, unknown>).statusCode === 'number'
  ) {
    return (error as Record<string, number>).statusCode;
  }
  if (
    error &&
    typeof error === 'object' &&
    'response' in error &&
    typeof (error as Record<string, unknown>).response === 'object' &&
    (error as Record<string, Record<string, unknown>>).response !== null &&
    'statusCode' in (error as Record<string, Record<string, unknown>>).response
  ) {
    return (error as Record<string, Record<string, number>>).response
      .statusCode;
  }
  return 500;
}
