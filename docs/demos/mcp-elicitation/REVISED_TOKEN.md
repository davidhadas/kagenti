# JWT Token Authentication - Extracting user_id and session_key

## Overview

The backend now uses Keycloak JWT tokens for authentication. The `user_id` and `session_key` are extracted from standard JWT claims instead of custom headers.

## JWT Token Structure

A Keycloak JWT token has three parts separated by dots: `header.payload.signature`

Example token:
```
eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJqdGkiOiJvbnJ0cm86OGFlMGU1ZDAtYTc0YS03Y2Y3LTRmNWUtNjQyNzY2ODFlNjQ3Iiwic3ViIjoiYWxpY2UiLCJwcmVmZXJyZWRfdXNlcm5hbWUiOiJhbGljZSIsImV4cCI6MTcxNDU2NzgwMH0.signature
```

## Extracting Claims from JWT

### Step 1: Extract the Payload

The payload is the second part of the JWT (between the two dots).

```go
parts := strings.Split(token, ".")
if len(parts) != 3 {
    return nil, fmt.Errorf("invalid JWT format")
}
payload := parts[1]
```

### Step 2: Base64 Decode the Payload

The payload is base64-URL encoded without padding.

```go
// Add padding if needed
if l := len(payload) % 4; l > 0 {
    payload += strings.Repeat("=", 4-l)
}

payloadBytes, err := base64.URLEncoding.DecodeString(payload)
if err != nil {
    return nil, fmt.Errorf("failed to decode payload: %w", err)
}
```

### Step 3: Parse JSON Claims

```go
var claims struct {
    JTI               string `json:"jti"`                // JWT ID - used as session_key
    Sub               string `json:"sub"`                // Subject (user ID)
    PreferredUsername string `json:"preferred_username"` // Username - preferred for user_id
}

if err := json.Unmarshal(payloadBytes, &claims); err != nil {
    return nil, fmt.Errorf("failed to parse claims: %w", err)
}
```

## Extracting user_id

**Preferred**: Use `preferred_username` claim
**Fallback**: Use `sub` claim if `preferred_username` is empty

```go
func getUserID(claims *Claims) string {
    if claims.PreferredUsername != "" {
        return claims.PreferredUsername
    }
    return claims.Sub
}
```

**Example**:
- Token has `"preferred_username": "alice"` → user_id = `"alice"`
- Token has `"sub": "123e4567-e89b-12d3-a456-426614174000"` → user_id = `"123e4567-e89b-12d3-a456-426614174000"`

## Extracting session_key

**Source**: `jti` (JWT ID) claim
**Important**: Keycloak's `jti` format includes a prefix that must be stripped

### Keycloak jti Format

Keycloak generates `jti` in the format: `<prefix>:<uuid>`

Example: `"jti": "onrtro:8ae0e5d0-a74a-7cf7-4f5e-64276681e647"`

Where:
- `onrtro` = prefix (realm/client identifier)
- `8ae0e5d0-a74a-7cf7-4f5e-64276681e647` = UUID

### Extracting UUID from jti

```go
func extractUUIDFromJTI(jti string) string {
    // Find the last colon
    if idx := strings.LastIndex(jti, ":"); idx != -1 {
        // Return everything after the last colon
        return jti[idx+1:]
    }
    // If no colon found, return the whole jti (already a UUID)
    return jti
}
```

**Examples**:
- `"onrtro:8ae0e5d0-a74a-7cf7-4f5e-64276681e647"` → `"8ae0e5d0-a74a-7cf7-4f5e-64276681e647"`
- `"8ae0e5d0-a74a-7cf7-4f5e-64276681e647"` → `"8ae0e5d0-a74a-7cf7-4f5e-64276681e647"` (no change)

## Complete Example

```go
package main

import (
    "encoding/base64"
    "encoding/json"
    "fmt"
    "strings"
)

type Claims struct {
    JTI               string `json:"jti"`
    Sub               string `json:"sub"`
    PreferredUsername string `json:"preferred_username"`
}

func extractClaimsFromToken(token string) (*Claims, error) {
    // Step 1: Split token
    parts := strings.Split(token, ".")
    if len(parts) != 3 {
        return nil, fmt.Errorf("invalid JWT format")
    }

    // Step 2: Decode payload
    payload := parts[1]
    if l := len(payload) % 4; l > 0 {
        payload += strings.Repeat("=", 4-l)
    }

    payloadBytes, err := base64.URLEncoding.DecodeString(payload)
    if err != nil {
        return nil, fmt.Errorf("failed to decode payload: %w", err)
    }

    // Step 3: Parse JSON
    var claims Claims
    if err := json.Unmarshal(payloadBytes, &claims); err != nil {
        return nil, fmt.Errorf("failed to parse claims: %w", err)
    }

    return &claims, nil
}

func extractUUIDFromJTI(jti string) string {
    if idx := strings.LastIndex(jti, ":"); idx != -1 {
        return jti[idx+1:]
    }
    return jti
}

func getUserID(claims *Claims) string {
    if claims.PreferredUsername != "" {
        return claims.PreferredUsername
    }
    return claims.Sub
}

func main() {
    // Example: Extract from Authorization header
    authHeader := "Bearer eyJhbGc..."
    
    // Remove "Bearer " prefix
    token := strings.TrimPrefix(authHeader, "Bearer ")
    
    // Extract claims
    claims, err := extractClaimsFromToken(token)
    if err != nil {
        panic(err)
    }
    
    // Get user_id and session_key
    userID := getUserID(claims)
    sessionKey := extractUUIDFromJTI(claims.JTI)
    
    fmt.Printf("user_id: %s\n", userID)
    fmt.Printf("session_key: %s\n", sessionKey)
}
```

## AuthBridge Integration

AuthBridge should:

1. **Extract Bearer token** from `Authorization` header
2. **Parse JWT** to get claims
3. **Extract user_id** from `preferred_username` (or `sub`)
4. **Extract session_key** from `jti` (strip prefix)
5. **Forward to MCP server** with extracted values

### Backward Compatibility (Optional)

AuthBridge can support both authentication methods:

```go
// Try Bearer token first
if authHeader := r.Header.Get("Authorization"); strings.HasPrefix(authHeader, "Bearer ") {
    token := strings.TrimPrefix(authHeader, "Bearer ")
    claims, err := extractClaimsFromToken(token)
    if err == nil {
        userID = getUserID(claims)
        sessionKey = extractUUIDFromJTI(claims.JTI)
    }
}

// Fallback to legacy headers if Bearer token not present or invalid
if userID == "" {
    userID = r.Header.Get("X-User-ID")
}
if sessionKey == "" {
    sessionKey = r.Header.Get("X-OAuth-Session-Key")
}
```

## Security Notes

1. **No Signature Verification**: The current implementation does NOT verify the JWT signature. This is acceptable for internal communication within the cluster where the token has already been validated by the backend.

2. **Token Validation**: The backend validates tokens with Keycloak before caching them. AuthBridge trusts tokens that have passed backend validation.

3. **Expiration**: JWT tokens have an `exp` claim. AuthBridge should check if the token is expired:
   ```go
   if claims.Exp < time.Now().Unix() {
       return fmt.Errorf("token expired")
   }
   ```

## Reference Implementation

See `docs/demos/mcp-elicitation/internal/tokenbroker/api/handlers.go` for the complete implementation used by the token broker.

Key functions:
- `extractTokenClaims()` - Extracts and parses JWT claims
- `extractUUIDFromJTI()` - Strips prefix from jti
- `getUserID()` - Gets user_id from claims
- `validateBearerToken()` - Complete validation flow