import { startTestBackend } from '@backstage/backend-test-utils';
import { toolhivePlugin } from './plugin';
import request from 'supertest';

// Mock @kubernetes/client-node
jest.mock('@kubernetes/client-node', () => {
  return {
    KubeConfig: jest.fn().mockImplementation(() => ({
      loadFromDefault: jest.fn(),
      makeApiClient: jest.fn().mockReturnValue({
        listNamespacedCustomObject: jest.fn().mockResolvedValue({ items: [] }),
        listClusterCustomObject: jest.fn().mockResolvedValue({ items: [] }),
        getNamespacedCustomObject: jest.fn(),
        createNamespacedCustomObject: jest.fn(),
        deleteNamespacedCustomObject: jest.fn(),
      }),
    })),
    CustomObjectsApi: jest.fn(),
  };
});

describe('plugin', () => {
  it('should register and serve the servers endpoint', async () => {
    const { server } = await startTestBackend({
      features: [toolhivePlugin],
    });

    const response = await request(server).get('/api/toolhive/servers');
    expect(response.status).toBe(200);
    expect(response.body).toEqual({ items: [] });
  });
});
