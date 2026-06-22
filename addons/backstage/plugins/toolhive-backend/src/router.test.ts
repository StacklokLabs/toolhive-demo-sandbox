import {
  mockServices,
} from '@backstage/backend-test-utils';
import express from 'express';
import request from 'supertest';
import { createRouter } from './router';

// Mock @kubernetes/client-node
jest.mock('@kubernetes/client-node', () => {
  const mockListNamespacedCustomObject = jest.fn();
  const mockListClusterCustomObject = jest.fn();
  const mockGetNamespacedCustomObject = jest.fn();
  const mockDeleteNamespacedCustomObject = jest.fn();

  return {
    KubeConfig: jest.fn().mockImplementation(() => ({
      loadFromDefault: jest.fn(),
      makeApiClient: jest.fn().mockReturnValue({
        listNamespacedCustomObject: mockListNamespacedCustomObject,
        listClusterCustomObject: mockListClusterCustomObject,
        getNamespacedCustomObject: mockGetNamespacedCustomObject,
        deleteNamespacedCustomObject: mockDeleteNamespacedCustomObject,
      }),
    })),
    CustomObjectsApi: jest.fn(),
    // Expose the mocks for test access
    __mocks: {
      listNamespacedCustomObject: mockListNamespacedCustomObject,
      listClusterCustomObject: mockListClusterCustomObject,
      getNamespacedCustomObject: mockGetNamespacedCustomObject,
      deleteNamespacedCustomObject: mockDeleteNamespacedCustomObject,
    },
  };
});

// eslint-disable-next-line @typescript-eslint/no-require-imports
const k8sMocks = require('@kubernetes/client-node').__mocks;

describe('createRouter', () => {
  let app: express.Express;

  beforeEach(async () => {
    jest.clearAllMocks();
    const router = await createRouter({
      logger: mockServices.logger.mock(),
      config: mockServices.rootConfig(),
      httpAuth: mockServices.httpAuth(),
    });
    app = express();
    app.use(router);
  });

  describe('GET /servers', () => {
    it('should list servers across all namespaces', async () => {
      k8sMocks.listClusterCustomObject.mockResolvedValue({
        items: [
          {
            metadata: { name: 'test-server', namespace: 'default' },
            spec: { image: 'test:latest' },
            status: { phase: 'Ready' },
          },
        ],
      });

      const response = await request(app).get('/servers');

      expect(response.status).toBe(200);
      expect(response.body.items).toHaveLength(1);
      expect(response.body.items[0].metadata.name).toBe('test-server');
    });

    it('should list servers in a specific namespace', async () => {
      k8sMocks.listNamespacedCustomObject.mockResolvedValue({
        items: [],
      });

      const response = await request(app).get('/servers?namespace=default');

      expect(response.status).toBe(200);
      expect(response.body.items).toHaveLength(0);
    });
  });

  describe('GET /servers/:namespace/:name', () => {
    it('should get a specific server', async () => {
      k8sMocks.getNamespacedCustomObject.mockResolvedValue({
        metadata: { name: 'test-server', namespace: 'default' },
        spec: { image: 'test:latest' },
        status: { phase: 'Ready' },
      });

      const response = await request(app).get('/servers/default/test-server');

      expect(response.status).toBe(200);
      expect(response.body.metadata.name).toBe('test-server');
    });
  });

  describe('DELETE /servers/:namespace/:name', () => {
    it('should delete a server', async () => {
      k8sMocks.deleteNamespacedCustomObject.mockResolvedValue({});

      const response = await request(app).delete(
        '/servers/default/test-server',
      );

      expect(response.status).toBe(204);
    });
  });
});
