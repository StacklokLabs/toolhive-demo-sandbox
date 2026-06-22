import React, { useCallback, useEffect, useState } from 'react';
import {
  Content,
  Header,
  Page,
  InfoCard,
  StructuredMetadataTable,
  StatusOK,
  StatusPending,
  StatusError,
  StatusAborted,
  StatusRunning,
  Progress,
  ResponseErrorPanel,
} from '@backstage/core-components';
import { useApi, useRouteRef, useRouteRefParams } from '@backstage/frontend-plugin-api';
import { toolhiveApiRef } from '../../api';
import { MCPServer } from '../../api/types';
import { rootRouteRef, serverDetailRouteRef } from '../../routes';
import Button from '@material-ui/core/Button';
import Dialog from '@material-ui/core/Dialog';
import DialogActions from '@material-ui/core/DialogActions';
import DialogContent from '@material-ui/core/DialogContent';
import DialogContentText from '@material-ui/core/DialogContentText';
import DialogTitle from '@material-ui/core/DialogTitle';
import Grid from '@material-ui/core/Grid';
import Chip from '@material-ui/core/Chip';

/** Render a colored status indicator based on MCPServer phase. */
function PhaseStatus({ phase }: { phase?: string }) {
  switch (phase) {
    case 'Ready':
      return <StatusOK>Ready</StatusOK>;
    case 'Pending':
      return <StatusPending>Pending</StatusPending>;
    case 'Failed':
      return <StatusError>Failed</StatusError>;
    case 'Terminating':
      return <StatusRunning>Terminating</StatusRunning>;
    case 'Stopped':
      return <StatusAborted>Stopped</StatusAborted>;
    default:
      return <StatusPending>Unknown</StatusPending>;
  }
}

export const MCPServerDetailPage = () => {
  const { namespace, name } = useRouteRefParams(serverDetailRouteRef);
  const api = useApi(toolhiveApiRef);
  const listRoute = useRouteRef(rootRouteRef);

  const [server, setServer] = useState<MCPServer | undefined>();
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState<Error | undefined>();
  const [deleteDialogOpen, setDeleteDialogOpen] = useState(false);
  const [deleting, setDeleting] = useState(false);

  const fetchServer = useCallback(async () => {
    try {
      const result = await api.getServer(namespace, name);
      setServer(result);
      setError(undefined);
    } catch (e) {
      setError(e instanceof Error ? e : new Error(String(e)));
    } finally {
      setLoading(false);
    }
  }, [api, namespace, name]);

  useEffect(() => {
    fetchServer();
  }, [fetchServer]);

  const handleDelete = async () => {
    setDeleting(true);
    try {
      await api.deleteServer(namespace, name);
      if (listRoute) {
        window.location.href = listRoute();
      }
    } catch (e) {
      setError(e instanceof Error ? e : new Error(String(e)));
      setDeleting(false);
      setDeleteDialogOpen(false);
    }
  };

  if (loading) {
    return (
      <Page themeId="tool">
        <Header title="MCP Server" />
        <Content>
          <Progress />
        </Content>
      </Page>
    );
  }

  if (error) {
    return (
      <Page themeId="tool">
        <Header title="MCP Server" />
        <Content>
          <ResponseErrorPanel error={error} />
        </Content>
      </Page>
    );
  }

  if (!server) {
    return (
      <Page themeId="tool">
        <Header title="MCP Server" />
        <Content>
          <ResponseErrorPanel
            error={new Error(`Server '${name}' not found in namespace '${namespace}'`)}
          />
        </Content>
      </Page>
    );
  }

  const specMetadata: Record<string, React.ReactNode> = {
    Image: server.spec.image,
    Transport: server.spec.transport ?? 'stdio',
    'Proxy Mode': server.spec.proxyMode ?? 'streamable-http',
    'Proxy Port': server.spec.proxyPort ?? 8080,
    ...(server.spec.mcpPort !== undefined ? { 'MCP Port': server.spec.mcpPort } : {}),
    ...(server.spec.replicas !== undefined ? { Replicas: server.spec.replicas } : {}),
    ...(server.spec.backendReplicas !== undefined
      ? { 'Backend Replicas': server.spec.backendReplicas }
      : {}),
    ...(server.spec.args && server.spec.args.length > 0
      ? { Args: server.spec.args.join(' ') }
      : {}),
  };

  if (server.spec.env && server.spec.env.length > 0) {
    specMetadata['Environment Variables'] = (
      <div>
        {server.spec.env.map(e => (
          <Chip
            key={e.name}
            label={`${e.name}=${e.value}`}
            size="small"
            style={{ marginRight: 4, marginBottom: 4 }}
          />
        ))}
      </div>
    );
  }

  if (server.spec.permissionProfile) {
    specMetadata['Permission Profile'] =
      `${server.spec.permissionProfile.type}: ${server.spec.permissionProfile.name}`;
  }

  const statusMetadata: Record<string, React.ReactNode> = {
    Phase: <PhaseStatus phase={server.status?.phase} />,
    ...(server.status?.url !== undefined
      ? {
          URL:
            server.status.phase === 'Ready' ? (
              <a
                href={server.status.url}
                target="_blank"
                rel="noopener noreferrer"
              >
                {server.status.url}
              </a>
            ) : (
              server.status.url
            ),
        }
      : {}),
    ...(server.status?.message ? { Message: server.status.message } : {}),
    ...(server.status?.readyReplicas !== undefined
      ? { 'Ready Replicas': server.status.readyReplicas }
      : {}),
  };

  const generalMetadata: Record<string, React.ReactNode> = {
    Name: server.metadata.name,
    Namespace: server.metadata.namespace,
    ...(server.metadata.uid ? { UID: server.metadata.uid } : {}),
    ...(server.metadata.creationTimestamp
      ? { Created: server.metadata.creationTimestamp }
      : {}),
  };

  return (
    <Page themeId="tool">
      <Header
        title={server.metadata.name}
        subtitle={`Namespace: ${server.metadata.namespace}`}
      />
      <Content>
        <Grid container spacing={3}>
          <Grid item xs={12} md={6}>
            <InfoCard title="General">
              <StructuredMetadataTable metadata={generalMetadata} />
            </InfoCard>
          </Grid>

          <Grid item xs={12} md={6}>
            <InfoCard title="Status">
              <StructuredMetadataTable metadata={statusMetadata} />
            </InfoCard>
          </Grid>

          <Grid item xs={12}>
            <InfoCard title="Specification">
              <StructuredMetadataTable metadata={specMetadata} />
            </InfoCard>
          </Grid>

          {server.ingress && (
            <Grid item xs={12}>
              <InfoCard title="Ingress">
                <StructuredMetadataTable
                  metadata={{
                    URL: (
                      <a
                        href={server.ingress.url}
                        target="_blank"
                        rel="noopener noreferrer"
                      >
                        {server.ingress.url}
                      </a>
                    ),
                    Hostname: server.ingress.hostname,
                    Path: server.ingress.path,
                  }}
                />
              </InfoCard>
            </Grid>
          )}

          {server.status?.conditions && server.status.conditions.length > 0 && (
            <Grid item xs={12}>
              <InfoCard title="Conditions">
                <StructuredMetadataTable
                  metadata={Object.fromEntries(
                    server.status.conditions.map(c => [
                      c.type,
                      `${c.status}${c.reason ? ` (${c.reason})` : ''}${c.message ? ` - ${c.message}` : ''}`,
                    ]),
                  )}
                />
              </InfoCard>
            </Grid>
          )}

          <Grid item xs={12}>
            <Button
              variant="contained"
              color="secondary"
              onClick={() => setDeleteDialogOpen(true)}
            >
              Delete Server
            </Button>
          </Grid>
        </Grid>

        <Dialog
          open={deleteDialogOpen}
          onClose={() => setDeleteDialogOpen(false)}
        >
          <DialogTitle>Confirm Deletion</DialogTitle>
          <DialogContent>
            <DialogContentText>
              Are you sure you want to delete MCP server "{server.metadata.name}"
              in namespace "{server.metadata.namespace}"? This action cannot be
              undone.
            </DialogContentText>
          </DialogContent>
          <DialogActions>
            <Button
              onClick={() => setDeleteDialogOpen(false)}
              color="primary"
              disabled={deleting}
            >
              Cancel
            </Button>
            <Button
              onClick={handleDelete}
              color="secondary"
              disabled={deleting}
            >
              {deleting ? 'Deleting...' : 'Delete'}
            </Button>
          </DialogActions>
        </Dialog>
      </Content>
    </Page>
  );
};
