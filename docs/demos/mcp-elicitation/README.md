# MCP Elicitation Demo

## Overview

This demo showcases Kagenti's integration with Model Context Protocol (MCP) servers, demonstrating how agents imported via the Kagenti dashboard automatically receive authbridge sidecar injection for secure, authenticated communication with MCP servers.

## Key Concepts

### Authbridge Sidecar Injection

When you import an agent through the Kagenti dashboard:

1. **Automatic Injection**: The kagenti-operator webhook automatically injects an authbridge sidecar into the agent pod
2. **Transparent Authentication**: The sidecar intercepts all outbound HTTP calls from the agent and adds OAuth tokens
3. **Token Broker Integration**: The authbridge sidecar consults the Token Broker to obtain OAuth tokens
4. **No Code Changes**: Your agent code doesn't need to handle authentication - it's all transparent

### Architecture Flow

```
User → Backend → Kagenti Agent (with authbridge sidecar) → MCP Server
                        ↓
                  Token Broker (provides OAuth tokens)
```

## Components

This demo deploys the following infrastructure components in the `kagenti-mcp-elicitation` namespace:

- **MCP Server**: Model Context Protocol server (`ghcr.io/davidhadas/kagenti-mcp-server:latest`) - Standalone service endpoint
- **Token Broker**: OAuth token management service (`ghcr.io/davidhadas/kagenti-token-broker:latest`)
- **Backend**: User interface and request handler (`ghcr.io/davidhadas/kagenti-backend:latest`)

**Note**: Agents are NOT deployed as static manifests. They are imported dynamically via the Kagenti dashboard.

## Prerequisites

- Kubernetes cluster with Kagenti installed
- Kagenti operator running (for automatic authbridge injection)
- kubectl configured to access the cluster
- Access to the Kagenti dashboard UI
- OAuth credentials for external services (if needed)

## Deployment Steps

### Step 1: Deploy Infrastructure

Deploy the supporting services (MCP Server, Token Broker, Backend):

```bash
# Deploy all infrastructure components
./scripts/deploy.sh

# Verify deployment
kubectl get pods -n kagenti-mcp-elicitation
```

Expected output:
```
NAME                            READY   STATUS    RESTARTS   AGE
mcp-server-xxx                  1/1     Running   0          1m
token-broker-xxx                1/1     Running   0          1m
backend-xxx                     1/1     Running   0          1m
```

### Step 2: Import Agent via Dashboard

Agents are imported through the Kagenti dashboard, which triggers automatic authbridge sidecar injection:

1. **Access the Kagenti Dashboard**:
   ```bash
   # Get the dashboard URL (adjust based on your installation)
   kubectl get ingress -n kagenti-system
   ```

2. **Navigate to Agent Import**:
   - Open the Kagenti dashboard in your browser
   - Go to the "Agents" section
   - Click "Import Agent" or "Add New Agent"

3. **Configure the Agent**:
   - **Agent Name**: Choose a descriptive name (e.g., `mcp-elicitation-agent`)
   - **Agent Image**: Specify your agent container image
   - **Namespace**: Select `kagenti-mcp-elicitation`
   - **MCP Server URL**: `http://mcp-server.kagenti-mcp-elicitation.svc.cluster.local:8184`

4. **Import and Verify**:
   - Click "Import" or "Create"
   - The kagenti-operator will automatically:
     - Create the agent pod
     - Inject the authbridge sidecar
     - Configure the sidecar to use the Token Broker
   
   Verify the agent pod has the authbridge sidecar:
   ```bash
   kubectl get pods -n kagenti-mcp-elicitation -l app.kubernetes.io/component=agent
   kubectl describe pod <agent-pod-name> -n kagenti-mcp-elicitation
   ```
   
   You should see two containers in the pod:
   - The agent container
   - The authbridge sidecar container

### Step 3: Configure Agent to Call MCP Server

Once the agent is imported with the authbridge sidecar:

1. **Agent Configuration**: Configure your agent to make HTTP calls to the MCP Server:
   ```
   MCP_SERVER_URL=http://mcp-server.kagenti-mcp-elicitation.svc.cluster.local:8184
   ```

2. **Automatic Authentication**: The authbridge sidecar will automatically:
   - Intercept outbound calls to the MCP Server
   - Consult the Token Broker for an OAuth token
   - Add the OAuth token to the request headers
   - Forward the authenticated request to the MCP Server

3. **No Code Changes Required**: Your agent code makes standard HTTP calls - authentication is handled transparently by the authbridge sidecar

### Step 4: Test the Integration

Test that the agent can successfully communicate with the MCP Server:

```bash
# View agent logs
kubectl logs -n kagenti-mcp-elicitation <agent-pod-name> -c agent

# View authbridge sidecar logs
kubectl logs -n kagenti-mcp-elicitation <agent-pod-name> -c authbridge

# View MCP Server logs
kubectl logs -n kagenti-mcp-elicitation -l app.kubernetes.io/name=mcp-server
```

## How Authbridge Injection Works

### Automatic Injection Process

1. **Dashboard Import**: When you import an agent via the Kagenti dashboard
2. **Webhook Trigger**: The kagenti-operator mutating webhook intercepts the pod creation
3. **Sidecar Injection**: The webhook automatically adds the authbridge sidecar container to the pod spec
4. **Configuration**: The sidecar is configured with:
   - Token Broker URL
   - Service mesh integration
   - Network interception rules

### Authbridge Sidecar Responsibilities

- **Intercept Outbound Calls**: Captures all HTTP/HTTPS requests from the agent
- **Token Acquisition**: Requests OAuth tokens from the Token Broker
- **Token Addition**: Adds `Authorization: Bearer <token>` headers to requests
- **Transparent Operation**: Agent code doesn't need authentication logic

### Token Broker Role

- **Credential Storage**: Stores OAuth client credentials securely
- **Token Issuance**: Issues OAuth tokens to authbridge sidecars
- **Token Management**: Handles token refresh and lifecycle

## Troubleshooting

### Agent Pod Not Starting

If the agent pod doesn't start after import:

```bash
# Check pod status
kubectl get pods -n kagenti-mcp-elicitation

# Check pod events
kubectl describe pod <agent-pod-name> -n kagenti-mcp-elicitation

# Check kagenti-operator logs
kubectl logs -n kagenti-system -l app=kagenti-operator
```

### Authbridge Sidecar Not Injected

If the authbridge sidecar is not injected:

1. Verify the kagenti-operator is running:
   ```bash
   kubectl get pods -n kagenti-system -l app=kagenti-operator
   ```

2. Check the mutating webhook configuration:
   ```bash
   kubectl get mutatingwebhookconfigurations
   ```

3. Ensure the agent was imported via the dashboard (not deployed as a static manifest)

### Authentication Failures

If the agent cannot authenticate with the MCP Server:

1. Check Token Broker logs:
   ```bash
   kubectl logs -n kagenti-mcp-elicitation -l app.kubernetes.io/name=token-broker
   ```

2. Verify OAuth credentials are configured:
   ```bash
   kubectl get secret mcp-elicitation-oauth-secret -n kagenti-mcp-elicitation
   ```

3. Check authbridge sidecar logs:
   ```bash
   kubectl logs -n kagenti-mcp-elicitation <agent-pod-name> -c authbridge
   ```

## Cleanup

```bash
# Remove all demo components
./scripts/cleanup.sh

# Or manually delete the namespace
kubectl delete namespace kagenti-mcp-elicitation
```

## Architecture

See [ARCHITECTURE.md](./ARCHITECTURE.md) for detailed architecture information including:
- Component diagrams
- Authentication flow
- Security considerations
- Deployment order

## Additional Documentation

- [Main Kagenti Documentation](../../README.md)
- [Authbridge Combined Sidecar](../../authbridge-combined-sidecar.md)
- [Identity Guide](../../identity-guide.md)
- [Model Context Protocol Specification](https://modelcontextprotocol.io/)

## Key Takeaways

1. **Agents are imported via dashboard**: Don't deploy agents as static Kubernetes manifests
2. **Automatic authbridge injection**: The kagenti-operator automatically injects the authbridge sidecar
3. **Transparent authentication**: Agent code doesn't need to handle OAuth - the sidecar does it
4. **Token Broker centralization**: OAuth credentials are managed centrally by the Token Broker
5. **MCP Server is standalone**: The MCP Server doesn't need authbridge - it receives authenticated requests

## Status

🚧 **Work in Progress** - This demo is currently under development.