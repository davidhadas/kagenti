# Plan: Integrate Keycloak Auth into Token Broker Backend

## Context

The MCP elicitation demo has two backend implementations:
- **Legacy** (`backend/main.go`) — deployed, uses Keycloak auth but no Token Broker
- **Envoy** (`internal/backend/envoy/`) — not deployed, has full Token Broker integration but no Keycloak auth

Per the Kagenti MCP Elicitation URL Mode spec, the backend must do BOTH: authenticate via Keycloak AND orchestrate the full Token Broker session flow (`POST /sessions`, event long-polling, OAuth callbacks, `X-OAuth-Session-Key` to Agent). Additionally, all HTTP calls to BOTH the Token Broker and the Agent must include `Authorization: Bearer <keycloak_token>`.

## Approach

Rewrite `backend/main.go` to use the envoy package as its core, injecting Keycloak authentication. Define an `Authenticator` interface in the envoy package so it stays independent of Keycloak specifics. Store a per-user `getToken` closure on each session so long-running goroutines (event polling) can refresh tokens. Align the envoy package's Agent communication to match the legacy backend's A2A JSON-RPC 2.0 protocol exactly.

## Changes

### 1. `internal/backend/envoy/client.go` — Add Bearer token + fix Agent communication format

**Bearer token on all calls:** Add `bearerToken string` parameter to every method:
- `CreateSession(ctx, userID, bearerToken)` 
- `PollEvents(ctx, sessionKey, userID, bearerToken)`
- `CompleteOAuth(ctx, sessionKey, userID, code, state, bearerToken)`
- `EndSession(ctx, sessionKey, userID, bearerToken)`

In each method, add `req.Header.Set("Authorization", "Bearer "+bearerToken)` before sending.

**Fix `ForwardToAgent` to match legacy backend exactly:**

Current envoy `ForwardToAgent` sends:
- URL: `agentURL` (no trailing slash)
- Body: `{"user_id": "...", "task": "..."}` (simple JSON)
- Headers: `Content-Type`, `X-OAuth-Session-Key`, `X-User-ID` (no Bearer)

Legacy backend sends:
- URL: `config.AIAgentURL + "/"` (trailing slash — A2A root endpoint)
- Body: A2A JSON-RPC 2.0 (`{jsonrpc: "2.0", id: "task-{userID}-{nanos}", method: "message/send", params: {message: {role: "user", messageId: "msg-{userID}-{nanos}", parts: [{type: "text", text: task}]}}}`)
- Headers: `Content-Type: application/json`, `Authorization: Bearer <token>`, `X-User-ID`

Change `ForwardToAgent` to:
- **New signature:** `ForwardToAgent(ctx, agentURL, sessionKey, userID, task, bearerToken string)` — accept `task` string instead of raw `[]byte` body
- **Build A2A JSON-RPC 2.0 body** inside the method (same format as legacy `handleTask`)
- **URL:** append `"/"` to `agentURL`
- **Headers:** set `Content-Type: application/json`, `Authorization: Bearer <token>`, `X-User-ID`, `X-OAuth-Session-Key`

### 2. `internal/backend/envoy/handlers.go` — Accept credentials, authenticate, use task string

**Handler struct changes:**
- Add `authenticator Authenticator` and `agentURL string` fields. Update `NewHandler`.

**`HandleTask` changes:**
- Update request struct to include `username` and `password`
- Validate credentials immediately via `h.authenticator.GetUserToken(username, password)` — return 401 on failure
- Create a `getToken` closure capturing the credentials
- Pass to `CreateSession` and `processTask`

**`processTask` changes:**
- Call `getToken()` to get Bearer token
- Pass `job.Task` (string) instead of marshaled body to `ForwardToAgent`
- Replace `os.Getenv("AGENT_SERVICE_URL")` with `h.agentURL`

**`HandleOAuthCallback` changes:**
- Retrieve session's `getToken`, use for the `CompleteOAuth` call

### 3. `internal/backend/envoy/session.go` — Thread token getter through sessions

- Add `Authenticator` interface:
  ```go
  type Authenticator interface {
      GetUserToken(username, password string) (string, error)
  }
  ```
- Add `getToken func() (string, error)` field to `UserSession`
- Update `CreateSession(ctx, userID, agentURL, getToken)` to accept and store the token getter. Call `getToken()` for `POST /sessions`.
- Update `pollEvents()` to call `session.getToken()` before each poll.
- Update `CompleteOAuth()` to call `getToken()` for Bearer token.
- Update `EndSession()` to call `getToken()` for Bearer token.

### 4. `backend/main.go` — Rewrite as thin wiring layer

- Expand Config: add `TokenBrokerURL string`.
- Read `TOKEN_BROKER_URL` from env/config via viper.
- Create `keycloakClient`, `sessionManager`, `jobManager`, `handler` using envoy package.
- Register routes: `/task` → `handler.HandleTask`, `/job/{id}` → `handler.HandleJobStatus`, `/callback` → `handler.HandleOAuthCallback`, `/events` → `handler.HandleEvents`, `/session/end` → `handler.HandleEndSession`, `/health`, `/demo`.
- Remove: inline handler functions (`handleTask`, `handleChat`, `handleCallback`, `handleTokenExchange`), global `keycloakClient`, `aiagent` import.
- Keep: CORS middleware, demo page serving, version logging.

### 5. `backend-config.yaml` — Add token_broker_url

```yaml
port: 8187
aiagent_url: "http://localhost:8185"
token_broker_url: "http://localhost:8190"
demo_page_path: "/usr/share/nginx/html/index.html"
```

### 6. `k8s/04-backend.yaml` — Update ConfigMap

Add `token_broker_url`, `keycloak_url`, `keycloak_realm` to the `backend-config` ConfigMap.

### 7. No changes to: `Dockerfile`, `job.go`, `internal/keycloak/client.go`

`keycloak.Client` already satisfies the `Authenticator` interface. The Dockerfile already copies `internal/` and builds from `backend/main.go`.

## Agent Communication Summary (after changes)

All calls to the Agent will use:
- **Endpoint:** `POST {agentURL}/` (trailing slash, A2A root)
- **Headers:** `Content-Type: application/json`, `Authorization: Bearer <keycloak_token>`, `X-User-ID: <userID>`, `X-OAuth-Session-Key: <sessionKey>`
- **Body:** A2A JSON-RPC 2.0:
  ```json
  {
    "jsonrpc": "2.0",
    "id": "task-{userID}-{timestamp}",
    "method": "message/send",
    "params": {
      "message": {
        "role": "user",
        "messageId": "msg-{userID}-{timestamp}",
        "parts": [{"type": "text", "text": "{task}"}]
      }
    }
  }
  ```

## Implementation Order

1. `client.go` — add bearerToken param, rewrite ForwardToAgent for A2A JSON-RPC
2. `session.go` — add Authenticator interface, getToken on session, thread tokens
3. `handlers.go` — add authenticator/agentURL, accept credentials, pass task string
4. `backend/main.go` — rewrite to use envoy package
5. `backend-config.yaml` — add token_broker_url
6. `k8s/04-backend.yaml` — update ConfigMap

## Verification

1. `cd docs/demos/mcp-elicitation && go build ./backend/` — must compile
2. `go vet ./...` — no issues
3. Deploy to Kind cluster using `scripts/deploy.sh`
4. Test: POST `/task` with username/password → should get 202 + job_id
5. Test: GET `/job/{id}` → should show status progression
6. Test: OAuth callback flow → Token Broker receives code+state with Bearer token
7. Verify logs: Agent receives A2A JSON-RPC 2.0 with both Bearer token and X-OAuth-Session-Key
