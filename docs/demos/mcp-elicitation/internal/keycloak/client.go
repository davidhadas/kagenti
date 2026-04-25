package keycloak

import (
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"net/url"
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

// CachedToken holds a token with expiration
type CachedToken struct {
	Token     string
	ExpiresAt time.Time
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
	// Check cache first
	cacheKey := fmt.Sprintf("%s:%s", username, password)
	c.cacheMutex.RLock()
	if cached, exists := c.cache[cacheKey]; exists {
		if time.Now().Before(cached.ExpiresAt) {
			c.cacheMutex.RUnlock()
			return cached.Token, nil
		}
	}
	c.cacheMutex.RUnlock()

	// Request new token
	tokenURL := fmt.Sprintf("%s/realms/%s/protocol/openid-connect/token",
		c.config.URL, c.config.Realm)

	data := url.Values{}
	data.Set("grant_type", "password")
	data.Set("client_id", "kagenti-backend")
	data.Set("username", username)
	data.Set("password", password)
	data.Set("scope", "openid profile email")
	// Request audience for the AI Agent to satisfy AuthBridge validation
	// The audience must match the client ID that AuthBridge expects
	data.Set("audience", "git-issue-agent")

	resp, err := c.httpClient.PostForm(tokenURL, data)
	if err != nil {
		return "", fmt.Errorf("failed to request token: %w", err)
	}
	defer resp.Body.Close()

	if resp.StatusCode != http.StatusOK {
		body, _ := io.ReadAll(resp.Body)
		return "", fmt.Errorf("keycloak returned status %d: %s", resp.StatusCode, string(body))
	}

	var tokenResp TokenResponse
	if err := json.NewDecoder(resp.Body).Decode(&tokenResp); err != nil {
		return "", fmt.Errorf("failed to decode token response: %w", err)
	}

	// Cache the token (with 30 second buffer before expiration)
	expiresAt := time.Now().Add(time.Duration(tokenResp.ExpiresIn-30) * time.Second)
	c.cacheMutex.Lock()
	c.cache[cacheKey] = &CachedToken{
		Token:     tokenResp.AccessToken,
		ExpiresAt: expiresAt,
	}
	c.cacheMutex.Unlock()

	return tokenResp.AccessToken, nil
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
