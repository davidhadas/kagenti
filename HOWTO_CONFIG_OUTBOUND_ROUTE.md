# AuthBridge Configuration for Different Actions per MCP Tool

Based on my investigation of the Kagenti codebase, here's a comprehensive explanation of how to configure authbridge to use different actions ("passthrough" or "exchange") for different MCP tools:

## Configuration Mechanisms

AuthBridge supports **two complementary configuration mechanisms** for controlling authentication behavior:

### 1. **Default Outbound Policy** (Global Setting)
Sets the default behavior for all outbound requests from an agent.

**Configuration Location:** `authbridge-config` ConfigMap in the agent's namespace

**Key:** `DEFAULT_OUTBOUND_POLICY`

**Values:** 
- `"passthrough"` - Forward requests without token exchange (default)
- `"exchange"` - Perform token exchange for all outbound requests

**How to Configure:**

#### Via Backend API (when creating/updating agents or tools):
```python
# In CreateAgentRequest or CreateToolRequest
{
  "name": "my-agent",
  "namespace": "team1",
  "defaultOutboundPolicy": "passthrough",  # or "exchange"
  ...
}
```

#### Via Direct ConfigMap Update:
```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: authbridge-config
  namespace: team1
data:
  DEFAULT_OUTBOUND_POLICY: "passthrough"  # or "exchange"
  KEYCLOAK_URL: "http://keycloak-service.keycloak.svc:8080"
  KEYCLOAK_REALM: "kagenti"
  ISSUER: "https://keycloak.example.com/realms/kagenti"
```

#### Via Helm Values (for pre-configured namespaces):
The default is set in [`charts/kagenti/templates/agent-namespaces.yaml`](charts/kagenti/templates/agent-namespaces.yaml:139-161), but can be overridden per-namespace.

### 2. **Outbound Routes** (Per-Tool/Host Configuration)
Defines specific token exchange rules for individual MCP tools or hosts, overriding the default policy.

**Configuration Location:** `authproxy-routes` ConfigMap in the agent's namespace

**Format:** YAML list of route objects

**Route Structure:**
```python
class OutboundRoute(BaseModel):
    host: str                    # Target host (e.g., "github-tool.team1.svc")
    target_audience: str         # OAuth audience for token exchange
    token_scopes: str = "openid" # OAuth scopes (default: "openid")
```

**How to Configure:**

#### Via Backend API:
```python
# In CreateAgentRequest or CreateToolRequest
{
  "name": "my-agent",
  "namespace": "team1",
  "defaultOutboundPolicy": "passthrough",  # Default for all tools
  "outboundRoutes": [
    {
      "host": "github-tool.team1.svc",
      "target_audience": "https://github-tool.team1.svc",
      "token_scopes": "openid github:read"
    },
    {
      "host": "slack-tool.team1.svc", 
      "target_audience": "https://slack-tool.team1.svc",
      "token_scopes": "openid slack:write"
    }
  ],
  ...
}
```

#### Via Direct ConfigMap Creation:
```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: authproxy-routes
  namespace: team1
data:
  routes.yaml: |
    - host: github-tool.team1.svc
      target_audience: https://github-tool.team1.svc
      token_scopes: openid github:read
    - host: slack-tool.team1.svc
      target_audience: https://slack-tool.team1.svc
      token_scopes: openid slack:write
```

## Complete Configuration Example

Here's how to configure an agent to use **passthrough by default** but **exchange tokens** for specific MCP tools:

### Scenario: Agent with Mixed Authentication
- **Default:** Passthrough (no token exchange)
- **GitHub Tool:** Token exchange with GitHub-specific audience
- **Slack Tool:** Token exchange with Slack-specific audience
- **Weather Tool:** Passthrough (uses default)

### Configuration via Backend API:
```json
{
  "name": "research-agent",
  "namespace": "team1",
  "protocol": "a2a",
  "framework": "LangGraph",
  "deploymentMethod": "image",
  "containerImage": "ghcr.io/myorg/research-agent:latest",
  "authBridgeEnabled": true,
  "spireEnabled": true,
  "defaultOutboundPolicy": "passthrough",
  "outboundRoutes": [
    {
      "host": "github-tool.team1.svc",
      "target_audience": "https://keycloak.example.com/realms/kagenti",
      "token_scopes": "openid github:read github:write"
    },
    {
      "host": "slack-tool.team1.svc",
      "target_audience": "https://keycloak.example.com/realms/kagenti", 
      "token_scopes": "openid slack:channels:write"
    }
  ]
}
```

### Configuration via Kubernetes Manifests:

**1. authbridge-config ConfigMap (default policy):**
```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: authbridge-config
  namespace: team1
data:
  DEFAULT_OUTBOUND_POLICY: "passthrough"
  KEYCLOAK_URL: "http://keycloak-service.keycloak.svc:8080"
  KEYCLOAK_REALM: "kagenti"
  ISSUER: "https://keycloak.example.com/realms/kagenti"
  SPIRE_ENABLED: "true"
```

**2. authproxy-routes ConfigMap (per-tool overrides):**
```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: authproxy-routes
  namespace: team1
data:
  routes.yaml: |
    - host: github-tool.team1.svc
      target_audience: https://keycloak.example.com/realms/kagenti
      token_scopes: openid github:read github:write
    - host: slack-tool.team1.svc
      target_audience: https://keycloak.example.com/realms/kagenti
      token_scopes: openid slack:channels:write
```

## How It Works

1. **AuthBridge Runtime Config:** The [`_build_authbridge_runtime_yaml()`](kagenti/backend/app/routers/agents.py:1911-1950) function generates the base configuration with `default_policy: "passthrough"` in the `outbound` section.

2. **ConfigMap Override:** When `defaultOutboundPolicy` is specified in the API request, it's written to the [`authbridge-config`](kagenti/backend/app/routers/agents.py:2800-2808) ConfigMap as `DEFAULT_OUTBOUND_POLICY`.

3. **Route-Specific Rules:** When `outboundRoutes` are specified, they're written to the [`authproxy-routes`](kagenti/backend/app/routers/agents.py:2024-2043) ConfigMap as a YAML list.

4. **AuthBridge Processing:** The AuthBridge sidecar reads both ConfigMaps:
   - Uses `DEFAULT_OUTBOUND_POLICY` for requests not matching any route
   - Uses route-specific settings (implicit "exchange" action) for matching hosts

## Key Files and Locations

- **Backend API Models:** [`kagenti/backend/app/routers/agents.py`](kagenti/backend/app/routers/agents.py:122-128) (OutboundRoute class, lines 122-128)
- **Backend API Models:** [`kagenti/backend/app/routers/agents.py`](kagenti/backend/app/routers/agents.py:257) (defaultOutboundPolicy field, line 257)
- **ConfigMap Creation:** [`kagenti/backend/app/routers/agents.py`](kagenti/backend/app/routers/agents.py:1953-2043) (_ensure_authbridge_configmaps and _ensure_authproxy_routes functions)
- **Helm Template:** [`charts/kagenti/templates/agent-namespaces.yaml`](charts/kagenti/templates/agent-namespaces.yaml:136-161) (authbridge-config ConfigMap)
- **Runtime Config Builder:** [`kagenti/backend/app/routers/agents.py`](kagenti/backend/app/routers/agents.py:1911-1950) (_build_authbridge_runtime_yaml function)
- **Test Examples:** [`kagenti/backend/tests/test_authbridge_runtime_config.py`](kagenti/backend/tests/test_authbridge_runtime_config.py:1-50)

## Important Notes

1. **Passthrough is Default:** The system defaults to `"passthrough"` mode, meaning no token exchange unless explicitly configured.

2. **Routes Override Default:** Any host matching an `outboundRoutes` entry will perform token exchange, regardless of the `defaultOutboundPolicy` setting.

3. **ConfigMap Precedence:** The `authbridge-config` ConfigMap can be manually edited after agent creation to change the default policy without redeploying.

4. **Namespace Scope:** All AuthBridge configuration is namespace-scoped, allowing different teams to have different authentication policies.

5. **No Demo Examples Found:** I did not find specific demo configurations in `docs/demos/mcp-elicitation/` showing authbridge configuration examples, but the mechanism is fully implemented in the backend API as documented above.