# AWS MCP Remote Proxy

Proxies MCP requests to the [AWS MCP Server](https://docs.aws.amazon.com/aws-mcp/) with Okta SSO authentication and AWS STS credential exchange.

## What it does

- Deploys an MCPRemoteProxy pointing to `https://aws-mcp.us-east-1.api.aws/mcp`
- Runs an embedded OAuth 2.0 authorization server with Okta as the upstream IDP
- Exchanges Okta access tokens for temporary AWS credentials via STS `AssumeRoleWithWebIdentity`
- Signs outgoing requests with SigV4 for the `aws-mcp` service

## Authentication flow

```
MCP Client (Claude Desktop, etc.)
  → OAuth 2.0 auth code flow with embedded auth server
  → User authenticates via Okta SSO
  → Embedded auth server issues ToolHive JWT (stores Okta token)
  → Client sends MCP request with ToolHive JWT
  → Proxy validates JWT, swaps for stored Okta token
  → STS exchanges Okta token for temporary AWS credentials
  → SigV4 signs request → forwarded to AWS MCP Server
```

## Prerequisites

- Demo sandbox cluster running (`bootstrap.sh` completed)
- An Okta OIDC Web Application (see setup below)
- AWS IAM OIDC provider + IAM role (see setup below)

## Okta setup

1. Create an OIDC Web Application in the Okta admin console:
   - Sign-in method: OIDC - OpenID Connect
   - Application type: Web Application
   - Grant types: Authorization Code
   - Sign-in redirect URI: `https://<AWS_MCP_HOSTNAME>/oauth/callback`
   - Scopes: openid, email, profile

2. Assign users/groups to the application.

3. Note the Client ID and Client Secret for `.env`.

The Okta issuer URL will be `https://<OKTA_DOMAIN>/oauth2/default`.

## AWS setup

1. Register Okta as an IAM OIDC Identity Provider:

   ```bash
   aws iam create-open-id-connect-provider \
     --url https://<OKTA_DOMAIN>/oauth2/default \
     --client-id-list api://default
   ```

   The client ID must be `api://default` (the `aud` claim in Okta's JWT access tokens from the default authorization server).

2. Create an IAM role with a trust policy allowing `AssumeRoleWithWebIdentity`:

   ```json
   {
     "Version": "2012-10-17",
     "Statement": [{
       "Effect": "Allow",
       "Principal": {
         "Federated": "arn:aws:iam::<ACCOUNT_ID>:oidc-provider/<OKTA_DOMAIN>/oauth2/default"
       },
       "Action": "sts:AssumeRoleWithWebIdentity",
       "Condition": {
         "StringEquals": {
           "<OKTA_DOMAIN>/oauth2/default:aud": "api://default"
         }
       }
     }]
   }
   ```

3. Attach a permission policy (e.g., S3 list access scoped to MCP):

   ```json
   {
     "Version": "2012-10-17",
     "Statement": [
       {
         "Sid": "AllowS3ListViaMCP",
         "Effect": "Allow",
         "Action": ["s3:ListAllMyBuckets", "s3:ListBucket"],
         "Resource": "*",
         "Condition": { "Bool": { "aws:ViaAWSMCPService": "true" } }
       },
       {
         "Sid": "DenyDirectAPIAccess",
         "Effect": "Deny",
         "Action": "*",
         "Resource": "*",
         "Condition": { "BoolIfExists": { "aws:ViaAWSMCPService": "false" } }
       }
     ]
   }
   ```

   The `aws:ViaAWSMCPService` condition ensures credentials only work through the MCP server.

   Note: Trust policy changes may take a few minutes to propagate in AWS.

## Deploy

```bash
cp .env.example .env   # fill in Okta + AWS values
./deploy.sh
```

## Connecting with Claude Code

The proxy is served over HTTPS via Traefik's traefik.me wildcard certificate. Node.js does not trust this CA by default, so launch Claude with TLS verification disabled:

```bash
NODE_TLS_REJECT_UNAUTHORIZED=0 claude
```

## Teardown

```bash
./teardown.sh
```

## Configuration

Edit `mcpremoteproxy.yaml` to customize:

- **Role mappings**: Map Okta groups to different IAM roles via `awsSts.roleMappings`
- **Session duration**: Adjust `awsSts.sessionDuration` (900–43200 seconds)
- **Permissions**: Create additional IAM roles with different policies
