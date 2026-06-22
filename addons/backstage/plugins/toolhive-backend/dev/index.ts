import { createBackend } from '@backstage/backend-defaults';
import { mockServices } from '@backstage/backend-test-utils';

// Development setup for the ToolHive backend plugin.
//
// Start up the backend by running `yarn start` in the package directory.
// Once it's up and running, try out the following requests:
//
// List all MCPServers:
//   curl http://localhost:7007/api/toolhive/servers
//
// Get a specific MCPServer:
//   curl http://localhost:7007/api/toolhive/servers/default/my-server
//
// Create a new MCPServer:
//   curl -X POST http://localhost:7007/api/toolhive/servers \
//     -H 'Content-Type: application/json' \
//     -d '{"name": "fetch-server", "image": "docker.io/mcp/fetch:latest"}'
//
// Delete an MCPServer:
//   curl -X DELETE http://localhost:7007/api/toolhive/servers/default/fetch-server

const backend = createBackend();

// Mocking auth services for development
backend.add(mockServices.auth.factory());
backend.add(mockServices.httpAuth.factory());

backend.add(import('../src'));

backend.start();
