# Backend Keycloak Authentication Implementation Guide

## Overview

This document describes the implementation needed in the backend (`github.com/davidhadas/github-mcp-server` repository, `authbridge_sidecar` branch) to authenticate with Keycloak using user-provided credentials and call the agent service with proper authorization.

## Architecture Flow

```
User (Browser) → Backend → Keycloak → Backend → Agent (with AuthBridge)
    ↓                ↓                    ↓              ↓
  username      Get Token           Bearer Token    Validate Token
  password      (Password Grant)    in Header       via AuthBridge
```

## Required Environment Variables

The backend deployment already includes these environment variables (see `04-backend.yaml`):

```yaml
- name: KEYCLOAK_URL
  value: "http://keycloak-service.keycloak.svc.cluster.local:8080"
- name: KEYCLOAK_REALM
  value: "kagenti"
- name: AGENT_SERVICE_URL
  value: "http://git-issue-agent.team1.svc.cluster.local:8080"
```

## Backend Code Implementation

### 1. Keycloak Configuration Structure

```go
package main

import (
    "encoding/json"
    "fmt"
    "net/http"
    "net/url"
    "os"
)

type KeycloakConfig struct {
    URL   string
    Realm string
}

func NewKeycloakConfig() *KeycloakConfig {
    return &KeycloakConfig{
        URL:   os.Getenv("KEYCLOAK_URL"),
        Realm: os.Getenv("KEYCLOAK_REALM"),
    }
}
```

### 2. Token Acquisition Function (Password Grant)

```go
type TokenResponse struct {
    AccessToken      string `json:"access_token"`
    ExpiresIn        int    `json:"expires_in"`
    RefreshToken     string `json:"refresh_token"`
    RefreshExpiresIn int    `json:"refresh_expires_in"`
    TokenType        string `json:"token_type"`
}

func (kc *KeycloakConfig) GetUserToken(username, password string) (*TokenResponse, error) {
    // Construct token endpoint URL
    tokenURL := fmt.Sprintf("%s/realms/%s/protocol/openid-connect/token", 
        kc.URL, kc.Realm)
    
    // Prepare form data for password grant
    data := url.Values{}
    data.Set("grant_type", "password")
    data.Set("client_id", "kagenti-ui")  // Use the existing kagenti-ui client
    data.Set("username", username)
    data.Set("password", password)
    
    // Make POST request to Keycloak
    resp, err := http.PostForm(tokenURL, data)
    if err != nil {
        return nil, fmt.Errorf("failed to request token: %w", err)
    }
    defer resp.Body.Close()
    
    // Check response status
    if resp.StatusCode != http.StatusOK {
        return nil, fmt.Errorf("keycloak returned status %d", resp.StatusCode)
    }
    
    // Parse response
    var tokenResp TokenResponse
    if err := json.NewDecoder(resp.Body).Decode(&tokenResp); err != nil {
        return nil, fmt.Errorf("failed to decode token response: %w", err)
    }
    
    return &tokenResp, nil
}
```

### 3. Update Task Request Structure

```go
type TaskRequest struct {
    Username string `json:"username"`
    Password string `json:"password"`
    Task     string `json:"task"`
    AgentURL string `json:"agent_url,omitempty"` // Optional override
}
```

### 4. Update Task Handler

```go
func (s *Server) handleTask(w http.ResponseWriter, r *http.Request) {
    // Parse request
    var req TaskRequest
    if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
        http.Error(w, "Invalid request", http.StatusBadRequest)
        return
    }
    
    // Validate required fields
    if req.Username == "" || req.Password == "" || req.Task == "" {
        http.Error(w, "username, password, and task are required", http.StatusBadRequest)
        return
    }
    
    // Get Keycloak token using user credentials
    tokenResp, err := s.keycloakConfig.GetUserToken(req.Username, req.Password)
    if err != nil {
        log.Printf("Failed to get Keycloak token: %v", err)
        http.Error(w, "Authentication failed", http.StatusUnauthorized)
        return
    }
    
    // Use default agent URL if not provided
    agentURL := req.AgentURL
    if agentURL == "" {
        agentURL = os.Getenv("AGENT_SERVICE_URL")
    }
    
    // Create job and call agent with token
    jobID := generateJobID()
    
    // Store job in background processing
    go s.processTask(jobID, agentURL, req.Task, tokenResp.AccessToken)
    
    // Return job ID immediately
    w.Header().Set("Content-Type", "application/json")
    json.NewEncoder(w).Encode(map[string]string{
        "job_id": jobID,
        "status": "pending",
    })
}
```

### 5. Agent Call with Authorization

```go
func (s *Server) callAgent(agentURL, task, accessToken string) (interface{}, error) {
    // Prepare request body
    reqBody := map[string]interface{}{
        "task": task,
    }
    jsonData, err := json.Marshal(reqBody)
    if err != nil {
        return nil, fmt.Errorf("failed to marshal request: %w", err)
    }
    
    // Create HTTP request
    req, err := http.NewRequest("POST", agentURL, bytes.NewBuffer(jsonData))
    if err != nil {
        return nil, fmt.Errorf("failed to create request: %w", err)
    }
    
    // Set headers - CRITICAL: Include Authorization header
    req.Header.Set("Content-Type", "application/json")
    req.Header.Set("Authorization", "Bearer "+accessToken)
    
    // Make request
    client := &http.Client{
        Timeout: 30 * time.Second,
    }
    resp, err := client.Do(req)
    if err != nil {
        return nil, fmt.Errorf("failed to call agent: %w", err)
    }
    defer resp.Body.Close()
    
    // Check response status
    if resp.StatusCode != http.StatusOK {
        body, _ := io.ReadAll(resp.Body)
        return nil, fmt.Errorf("agent returned status %d: %s", resp.StatusCode, string(body))
    }
    
    // Parse response
    var result interface{}
    if err := json.NewDecoder(resp.Body).Decode(&result); err != nil {
        return nil, fmt.Errorf("failed to decode response: %w", err)
    }
    
    return result, nil
}
```

### 6. Background Task Processing

```go
func (s *Server) processTask(jobID, agentURL, task, accessToken string) {
    // Update job status to processing
    s.updateJobStatus(jobID, "processing", nil, nil)
    
    // Call agent with authorization
    result, err := s.callAgent(agentURL, task, accessToken)
    if err != nil {
        log.Printf("Job %s failed: %v", jobID, err)
        s.updateJobStatus(jobID, "failed", nil, err)
        return
    }
    
    // Update job status to completed
    s.updateJobStatus(jobID, "completed", result, nil)
    log.Printf("Job %s completed successfully", jobID)
}
```

## Testing the Implementation

### 1. Create a Test User in Keycloak

```bash
# Access Keycloak admin console at http://localhost:8081
# Login with admin/admin
# Navigate to: Users → Add User
# - Username: demo-user
# - Email: demo@example.com
# - First Name: Demo
# - Last Name: User
# - Email Verified: ON
# Click "Create"

# Set password:
# - Go to Credentials tab
# - Set Password: demo-password
# - Temporary: OFF
# Click "Set Password"
```

### 2. Test the Flow

```bash
# 1. Rebuild and push backend image
cd /path/to/github-mcp-server
docker build -t ghcr.io/davidhadas/kagenti-backend:latest .
docker push ghcr.io/davidhadas/kagenti-backend:latest

# 2. Load into Kind cluster
kind load docker-image ghcr.io/davidhadas/kagenti-backend:latest --name kagenti

# 3. Apply updated deployment
kubectl apply -f docs/demos/mcp-elicitation/k8s/04-backend.yaml

# 4. Restart backend
kubectl rollout restart deployment/backend -n kagenti-mcp-elicitation

# 5. Wait for rollout
kubectl rollout status deployment/backend -n kagenti-mcp-elicitation

# 6. Test via UI
# Open http://localhost:8187
# Enter username: demo-user
# Enter password: demo-password
# Submit a task
```

### 3. Verify Authentication Flow

```bash
# Check backend logs
kubectl logs -n kagenti-mcp-elicitation deployment/backend --tail=50

# Check agent logs (should show authorized request)
kubectl logs -n team1 deployment/git-issue-agent --tail=50

# Check authbridge logs (should show token validation)
kubectl logs -n team1 deployment/git-issue-agent -c envoy-proxy --tail=50
```

## Error Handling

### Common Issues and Solutions

1. **401 Unauthorized from Keycloak**
   - Verify username/password are correct
   - Check user exists in Keycloak
   - Ensure user is in the correct realm (`kagenti`)

2. **401 Unauthorized from Agent**
   - Verify token is being passed in Authorization header
   - Check token format: `Bearer <token>`
   - Verify AuthBridge is configured correctly

3. **Token Expired**
   - Implement token refresh logic using refresh_token
   - Cache tokens with expiration tracking
   - Re-authenticate when token expires

## Security Considerations

1. **Password Handling**
   - Never log passwords
   - Use HTTPS in production
   - Consider implementing rate limiting

2. **Token Storage**
   - Don't store tokens in browser localStorage
   - Use secure session management
   - Implement token expiration handling

3. **Error Messages**
   - Don't expose detailed auth errors to users
   - Log detailed errors server-side only
   - Return generic "Authentication failed" messages

## Next Steps

After implementing this code:

1. ✅ Update backend code with Keycloak integration
2. ✅ Rebuild and push backend image
3. ✅ Load image into Kind cluster
4. ✅ Apply updated deployment manifest
5. ✅ Create test user in Keycloak
6. ✅ Test end-to-end flow
7. ✅ Verify logs show successful authentication

## References

- Keycloak Password Grant: https://www.keycloak.org/docs/latest/securing_apps/#_resource_owner_password_credentials_flow
- OAuth 2.0 Password Grant: https://oauth.net/2/grant-types/password/
- Keycloak REST API: https://www.keycloak.org/docs-api/latest/rest-api/

---
*Made with Bob*