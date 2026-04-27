package envoy

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"time"
)

// TokenBrokerClient is a client for the Token Broker service.
type TokenBrokerClient struct {
	baseURL string
	client  *http.Client
}

// NewTokenBrokerClient creates a new Token Broker client.
func NewTokenBrokerClient(baseURL string) *TokenBrokerClient {
	return &TokenBrokerClient{
		baseURL: baseURL,
		client: &http.Client{
			Timeout: 320 * time.Second, // Longer than Token Broker's 300s timeout
		},
	}
}

// CreateSession creates a new session with the Token Broker.
// The Token Broker will extract the session_key from the JWT token's claims.
// This method returns the session_key that was extracted from the token for verification.
func (c *TokenBrokerClient) CreateSession(ctx context.Context, userID, bearerToken string) (string, error) {
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, c.baseURL+"/sessions", nil)
	if err != nil {
		return "", fmt.Errorf("failed to create request: %w", err)
	}

	req.Header.Set("Authorization", "Bearer "+bearerToken)
	req.Header.Set("X-User-ID", userID)
	// Note: We no longer send X-OAuth-Session-Key header during session creation
	// The Token Broker will extract session_key from the JWT token claims

	resp, err := c.client.Do(req)
	if err != nil {
		return "", fmt.Errorf("failed to send request: %w", err)
	}
	defer resp.Body.Close()

	if resp.StatusCode != http.StatusCreated {
		body, _ := io.ReadAll(resp.Body)
		return "", fmt.Errorf("failed to create session: status %d, body: %s", resp.StatusCode, string(body))
	}

	var result struct {
		OAuthSessionKey string `json:"oauth_session_key"`
	}

	if err := json.NewDecoder(resp.Body).Decode(&result); err != nil {
		return "", fmt.Errorf("failed to decode response: %w", err)
	}

	// The Token Broker returns the session_key it extracted from the JWT token
	return result.OAuthSessionKey, nil
}

// PollEvents polls for events from the Token Broker (long-polling).
func (c *TokenBrokerClient) PollEvents(ctx context.Context, sessionKey, userID, bearerToken string) (*Event, error) {
	url := fmt.Sprintf("%s/sessions/%s/events", c.baseURL, sessionKey)
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, url, nil)
	if err != nil {
		return nil, fmt.Errorf("failed to create request: %w", err)
	}

	req.Header.Set("Authorization", "Bearer "+bearerToken)
	req.Header.Set("X-User-ID", userID)

	resp, err := c.client.Do(req)
	if err != nil {
		return nil, fmt.Errorf("failed to send request: %w", err)
	}
	defer resp.Body.Close()

	// 204 No Content means timeout (no events)
	if resp.StatusCode == http.StatusNoContent {
		return nil, fmt.Errorf("no events (timeout)")
	}

	if resp.StatusCode != http.StatusOK {
		body, _ := io.ReadAll(resp.Body)
		return nil, fmt.Errorf("failed to poll events: status %d, body: %s", resp.StatusCode, string(body))
	}

	var event Event
	if err := json.NewDecoder(resp.Body).Decode(&event); err != nil {
		return nil, fmt.Errorf("failed to decode event: %w", err)
	}

	return &event, nil
}

// CompleteOAuth completes an OAuth flow by sending the authorization code to the Token Broker.
func (c *TokenBrokerClient) CompleteOAuth(ctx context.Context, sessionKey, userID, code, state, bearerToken string) error {
	url := fmt.Sprintf("%s/sessions/%s/events?code=%s&state=%s", c.baseURL, sessionKey, code, state)
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, url, nil)
	if err != nil {
		return fmt.Errorf("failed to create request: %w", err)
	}

	req.Header.Set("Authorization", "Bearer "+bearerToken)
	req.Header.Set("X-User-ID", userID)

	resp, err := c.client.Do(req)
	if err != nil {
		return fmt.Errorf("failed to send request: %w", err)
	}
	defer resp.Body.Close()

	if resp.StatusCode != http.StatusOK {
		body, _ := io.ReadAll(resp.Body)
		return fmt.Errorf("failed to complete OAuth: status %d, body: %s", resp.StatusCode, string(body))
	}

	return nil
}

// EndSession ends a session with the Token Broker.
func (c *TokenBrokerClient) EndSession(ctx context.Context, sessionKey, userID, bearerToken string) error {
	url := fmt.Sprintf("%s/sessions/%s/end", c.baseURL, sessionKey)
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, url, nil)
	if err != nil {
		return fmt.Errorf("failed to create request: %w", err)
	}

	req.Header.Set("Authorization", "Bearer "+bearerToken)
	req.Header.Set("X-User-ID", userID)

	resp, err := c.client.Do(req)
	if err != nil {
		return fmt.Errorf("failed to send request: %w", err)
	}
	defer resp.Body.Close()

	if resp.StatusCode != http.StatusOK {
		body, _ := io.ReadAll(resp.Body)
		return fmt.Errorf("failed to end session: status %d, body: %s", resp.StatusCode, string(body))
	}

	return nil
}

// ForwardToAgent forwards a request to the AI Agent with A2A JSON-RPC 2.0 format.
func (c *TokenBrokerClient) ForwardToAgent(ctx context.Context, agentURL, sessionKey, userID, task, bearerToken string) ([]byte, error) {
	// Generate timestamp for unique IDs
	timestamp := time.Now().UnixNano()

	// Build A2A JSON-RPC 2.0 body
	a2aBody := map[string]interface{}{
		"jsonrpc": "2.0",
		"id":      fmt.Sprintf("task-%s-%d", userID, timestamp),
		"method":  "message/send",
		"params": map[string]interface{}{
			"message": map[string]interface{}{
				"role":      "user",
				"messageId": fmt.Sprintf("msg-%s-%d", userID, timestamp),
				"parts": []map[string]string{
					{
						"type": "text",
						"text": task,
					},
				},
			},
		},
	}

	bodyBytes, err := json.Marshal(a2aBody)
	if err != nil {
		return nil, fmt.Errorf("failed to marshal A2A body: %w", err)
	}

	// Append trailing slash to agentURL for A2A root endpoint
	url := agentURL + "/"

	req, err := http.NewRequestWithContext(ctx, http.MethodPost, url, bytes.NewReader(bodyBytes))
	if err != nil {
		return nil, fmt.Errorf("failed to create request: %w", err)
	}

	req.Header.Set("Content-Type", "application/json")
	req.Header.Set("Authorization", "Bearer "+bearerToken)
	req.Header.Set("X-User-ID", userID)
	req.Header.Set("X-OAuth-Session-Key", sessionKey)

	resp, err := c.client.Do(req)
	if err != nil {
		return nil, fmt.Errorf("failed to send request: %w", err)
	}
	defer resp.Body.Close()

	responseBody, err := io.ReadAll(resp.Body)
	if err != nil {
		return nil, fmt.Errorf("failed to read response body: %w", err)
	}

	if resp.StatusCode != http.StatusOK {
		return nil, fmt.Errorf("agent returned status %d: %s", resp.StatusCode, string(responseBody))
	}

	return responseBody, nil
}

// Made with Bob
