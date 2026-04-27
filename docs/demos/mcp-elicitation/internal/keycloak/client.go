package keycloak

import (
	"encoding/base64"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"strings"
	"sync"
	"time"
)

// Config holds Keycloak connection details
type Config struct {
	URL   string
	Realm string
}

// TokenResponse represents Keycloak token response
type TokenResponse struct {
	AccessToken      string `json:"access_token"`
	ExpiresIn        int    `json:"expires_in"`
	RefreshToken     string `json:"refresh_token"`
	RefreshExpiresIn int    `json:"refresh_expires_in"`
	TokenType        string `json:"token_type"`
}

// TokenWithClaims holds a token with its parsed claims
type TokenWithClaims struct {
	Token      string
	UserID     string
	SessionKey string // Will be populated from jti claim
	ExpiresAt  time.Time
}

// CachedToken holds a token with expiration
type CachedToken struct {
	Token     string
	ExpiresAt time.Time
}

// JWTClaims represents the standard claims in a Keycloak JWT token
type JWTClaims struct {
	Sub               string `json:"sub"`                // Subject (user ID)
	JTI               string `json:"jti"`                // JWT ID (unique token identifier) - used as session_key
	PreferredUsername string `json:"preferred_username"` // Username
	Exp               int64  `json:"exp"`                // Expiration time
}

// Client manages Keycloak authentication
type Client struct {
	config     *Config
	httpClient *http.Client
	cache      map[string]*CachedToken
	cacheMutex sync.RWMutex
}

// NewClient creates a new Keycloak client
func NewClient(keycloakURL, realm string) *Client {
	return &Client{
		config: &Config{
			URL:   keycloakURL,
			Realm: realm,
		},
		httpClient: &http.Client{
			Timeout: 10 * time.Second,
		},
		cache: make(map[string]*CachedToken),
	}
}

// GetUserToken obtains a Keycloak token using password grant
func (c *Client) GetUserToken(username, password string) (string, error) {
	tokenWithClaims, err := c.GetUserTokenWithClaims(username, password)
	if err != nil {
		return "", err
	}
	return tokenWithClaims.Token, nil
}

// GetUserTokenWithClaims obtains a Keycloak token and extracts jti as session_key
// The jti (JWT ID) claim is a unique identifier for each token, perfect for session management
// Note: We don't cache tokens because each token request should create a new session
// with a unique jti (session_key). Caching would reuse the same session_key for multiple sessions.
func (c *Client) GetUserTokenWithClaims(username, password string) (*TokenWithClaims, error) {
	// Request new token from Keycloak
	tokenURL := fmt.Sprintf("%s/realms/%s/protocol/openid-connect/token",
		c.config.URL, c.config.Realm)

	data := url.Values{}
	data.Set("grant_type", "password")
	data.Set("client_id", "kagenti-backend")
	data.Set("username", username)
	data.Set("password", password)
	data.Set("scope", "openid profile email")
	// Request audience for the AI Agent to satisfy AuthBridge validation
	data.Set("audience", "git-issue-agent")

	resp, err := c.httpClient.PostForm(tokenURL, data)
	if err != nil {
		return nil, fmt.Errorf("failed to request token: %w", err)
	}
	defer resp.Body.Close()

	if resp.StatusCode != http.StatusOK {
		body, _ := io.ReadAll(resp.Body)
		return nil, fmt.Errorf("keycloak returned status %d: %s", resp.StatusCode, string(body))
	}

	var tokenResp TokenResponse
	if err := json.NewDecoder(resp.Body).Decode(&tokenResp); err != nil {
		return nil, fmt.Errorf("failed to decode token response: %w", err)
	}

	// Parse JWT to extract claims (including jti which we'll use as session_key)
	claims, err := c.parseJWTClaims(tokenResp.AccessToken)
	if err != nil {
		return nil, fmt.Errorf("failed to parse token claims: %w", err)
	}

	// Use jti (JWT ID) as the session_key - it's unique per token
	if claims.JTI == "" {
		return nil, fmt.Errorf("token missing jti claim")
	}

	// Extract UUID from jti (Keycloak format is "prefix:uuid", we want just the UUID)
	sessionKey := extractUUIDFromJTI(claims.JTI)

	// Use preferred_username or sub as user_id
	userID := claims.PreferredUsername
	if userID == "" {
		userID = claims.Sub
	}
	if userID == "" {
		return nil, fmt.Errorf("token missing user identifier")
	}

	expiresAt := time.Unix(claims.Exp, 0)

	return &TokenWithClaims{
		Token:      tokenResp.AccessToken,
		UserID:     userID,
		SessionKey: sessionKey, // Use UUID part of jti as session_key
		ExpiresAt:  expiresAt,
	}, nil
}

// extractUUIDFromJTI extracts the UUID portion from Keycloak's jti claim
// Keycloak jti format is typically "prefix:uuid" (e.g., "onrtro:8ae0e5d0-a74a-7cf7-4f5e-64276681e647")
// We extract just the UUID part for cleaner session keys
func extractUUIDFromJTI(jti string) string {
	// Check if jti contains a colon (prefix:uuid format)
	if idx := strings.LastIndex(jti, ":"); idx != -1 {
		// Return the part after the last colon
		return jti[idx+1:]
	}
	// If no colon, return the whole jti (already a UUID)
	return jti
}

// parseJWTClaims parses a JWT token and extracts standard claims
// Note: This is a simple parser that doesn't verify the signature
func (c *Client) parseJWTClaims(token string) (*JWTClaims, error) {
	// Split the JWT into parts
	parts := strings.Split(token, ".")
	if len(parts) != 3 {
		return nil, fmt.Errorf("invalid JWT format")
	}

	// Decode the payload (second part)
	payload, err := base64.RawURLEncoding.DecodeString(parts[1])
	if err != nil {
		return nil, fmt.Errorf("failed to decode JWT payload: %w", err)
	}

	// Parse the claims
	var claims JWTClaims
	if err := json.Unmarshal(payload, &claims); err != nil {
		return nil, fmt.Errorf("failed to unmarshal JWT claims: %w", err)
	}

	return &claims, nil
}

// ClearCache clears the token cache
func (c *Client) ClearCache() {
	c.cacheMutex.Lock()
	defer c.cacheMutex.Unlock()
	c.cache = make(map[string]*CachedToken)
}

// CleanExpiredTokens removes expired tokens from cache
func (c *Client) CleanExpiredTokens() {
	c.cacheMutex.Lock()
	defer c.cacheMutex.Unlock()

	now := time.Now()
	for key, cached := range c.cache {
		if now.After(cached.ExpiresAt) {
			delete(c.cache, key)
		}
	}
}

// Made with Bob
