# MCP Elicitation Demo Architecture

## Overview

This document describes the architecture of the MCP Elicitation demo, which demonstrates Kagenti's integration with Model Context Protocol (MCP) servers. The demo showcases how agents imported via the Kagenti dashboard automatically receive authbridge sidecar injection for secure communication with MCP servers.

## Architecture Diagram

```
┌─────────────────────────────────────────────────────────────────────┐
│                     kagenti-mcp-elicitation                          │
│                            Namespace                                 │
├─────────────────────────────────────────────────────────────────────┤
│                                                                      │
│  ┌────────────┐                                                     │
│  │   User     │                                                     │
│  └─────┬──────┘                                                     │
│        │                                                             │
│        ▼                                                             │
│  ┌──────────────────────────────────────────────────────────────┐  │
│  │              Backend Service                                  │  │
│  │  (User Interface & Request Handling)                          │  │
│  └────────────────────────────┬─────────────────────────────────┘  │
│                               │                                     │
│                               ▼                                     │
│  ┌──────────────────────────────────────────────────────────────┐  │
│  │              Kagenti Agent Pod                                │  │
│  │              (Imported via Dashboard)                         │  │
│  │  ┌────────────────┐  ┌──────────────────────────────────┐   │  │
│  │  │  Agent         │  │  Authbridge Sidecar              │   │  │
│  │  │  Container     │◄─┤  (Auto-injected by Kagenti)     │   │  │
│  │  │                │  │  - Intercepts outbound calls     │   │  │
│  │  │                │  │  - Adds OAuth tokens             │   │  │
│  │  └────────────────┘  └──────────┬───────────────────────┘   │  │
│  └─────────────────────────────────┼───────────────────────────┘  │
│                                     │                               │
│                                     │ Consults for tokens           │
│                                     ▼                               │
│  ┌──────────────────────────────────────────────────────────────┐  │
│  │              Token Broker                                     │  │
│  │  (OAuth Token Management)                                     │  │
│  │  - Stores OAuth credentials                                   │  │
│  │  - Issues tokens to authbridge                                │  │
│  └──────────────────────────────────────────────────────────────┘  │
│                                     │                               │
│                                     │ Agent calls with OAuth token  │
│                                     ▼                               │
│  ┌──────────────────────────────────────────────────────────────┐  │
│  │              MCP Server                                       │  │
│  │  (Standalone Service - NO authbridge)                         │  │
│  │  - Receives authenticated requests from agents                │  │
│  │  - Implements Model Context Protocol                          │  │
│  └──────────────────────────────────────────────────────────────┘  │
│                                                                      │
└─────────────────────────────────────────────────────────────────────┘
```

## Components

### Kagenti Agent (Imported via Dashboard)

- **Deployment Method**: Imported dynamically through the Kagenti dashboard UI
- **Authbridge Sidecar**: Automatically injected by the kagenti-operator webhook when the agent is imported
- **Sidecar Image**: `ghcr.io/davidhadas/kagenti-extensions/authbridge:latest`
- **Purpose**: The agent executes AI tasks, while the authbridge sidecar handles authentication
- **Key Feature**: The authbridge sidecar intercepts all outbound HTTP calls from the agent and adds OAuth tokens

### MCP Server (Standalone Service)

- **Image**: `ghcr.io/davidhadas/kagenti-mcp-server:latest`
- **Purpose**: Implements the Model Context Protocol for tool integration
- **Deployment**: Deployed as a standard Kubernetes service (no authbridge injection needed)
- **Communication**: Receives authenticated requests from agents that have authbridge sidecars
- **Role**: Acts as a service endpoint that processes MCP protocol requests

### Token Broker

- **Image**: `ghcr.io/davidhadas/kagenti-token-broker:latest`
- **Purpose**: Centralized OAuth token management service
- **Role**:
  - Stores OAuth client credentials (CLIENT_ID, CLIENT_SECRET)
  - Issues OAuth tokens to authbridge sidecars upon request
  - Manages token lifecycle and refresh
- **Integration**: Consulted by authbridge sidecars when they need to authenticate outbound calls

### Backend Service

- **Image**: `ghcr.io/davidhadas/kagenti-backend:latest`
- **Purpose**: Provides the user interface and handles user requests
- **Integration**: Routes user requests to appropriate agents
- **Role**: Entry point for user interactions with the system

## Authentication Flow

1. **User Request**: User interacts with the Backend Service
2. **Agent Invocation**: Backend routes the request to a Kagenti Agent
3. **Agent Import**: Agent is imported via Kagenti dashboard (if not already present)
4. **Automatic Injection**: Kagenti-operator webhook automatically injects the authbridge sidecar into the agent pod
5. **Outbound Call Interception**: When the agent makes a call to the MCP Server, the authbridge sidecar intercepts it
6. **Token Acquisition**: Authbridge sidecar consults the Token Broker to obtain an OAuth token
7. **Token Addition**: Authbridge adds the OAuth token to the outbound request
8. **Authenticated Request**: MCP Server receives the authenticated request and processes it
9. **Response**: Response flows back through the authbridge to the agent, then to the backend, and finally to the user

## Agent Import Process

Agents are **not** deployed as static Kubernetes manifests. Instead, they are imported dynamically through the Kagenti dashboard:

1. **Access Dashboard**: Navigate to the Kagenti dashboard UI
2. **Import Agent**: Use the agent import feature to add a new agent
3. **Automatic Configuration**: The kagenti-operator automatically:
   - Creates the agent pod
   - Injects the authbridge sidecar
   - Configures the sidecar to use the Token Broker
4. **Ready to Use**: The agent is immediately available with full authentication capabilities

## Security Considerations

### Authbridge Sidecar Injection

- **Automatic Injection**: When agents are imported via the Kagenti dashboard, the kagenti-operator webhook automatically injects the authbridge sidecar
- **No Manual Configuration**: Developers don't need to manually add authbridge labels or configurations
- **Consistent Security**: All imported agents automatically get the same security posture

### Authentication Architecture

- **Token Broker Centralization**: OAuth credentials are stored centrally in the Token Broker, not in individual agent pods
- **Sidecar Interception**: The authbridge sidecar intercepts all outbound HTTP calls from the agent container
- **Automatic Token Addition**: OAuth tokens are automatically added to requests without agent code changes
- **MCP Server Simplicity**: The MCP Server is a simple service endpoint that receives authenticated requests

### Security Best Practices

- **Credential Isolation**: OAuth credentials are stored in Kubernetes secrets and accessed only by the Token Broker
- **Least Privilege**: Agents don't have direct access to OAuth credentials; they rely on the authbridge sidecar
- **Service Separation**: MCP Server is a standalone service without authentication responsibilities
- **Transparent Security**: Authentication is handled transparently by the authbridge sidecar

## Network Policies

(TODO: Define network policies for component communication)

## Deployment Order

The deployment follows this sequence:

1. **Namespace creation** (`00-namespace.yaml`)
2. **OAuth Secret** (`01-oauth-secret.yaml`) - Contains OAuth credentials for the Token Broker
3. **Token Broker** (`02-token-broker.yaml`) - Must be deployed before agents need tokens
4. **MCP Server** (`03-mcp-server.yaml`) - Standalone service endpoint
5. **Backend Service** (`04-backend.yaml`) - User interface and request handler
6. **Agent Import** - Agents are imported via the Kagenti dashboard (not deployed as manifests)

**Important**: Agents are NOT deployed using static manifests. They are imported dynamically through the Kagenti dashboard, which triggers automatic authbridge sidecar injection.

## Future Enhancements

- Add monitoring and observability
- Implement rate limiting
- Add circuit breakers for resilience
- Enhance logging and tracing

## References

- [Model Context Protocol Specification](https://modelcontextprotocol.io/)
- [Kagenti Authentication Guide](../../identity-guide.md)
- [Authbridge Documentation](../../authbridge-combined-sidecar.md)