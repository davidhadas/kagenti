package main

import (
	"fmt"
	"log/slog"
	"net/http"
	"os"

	"github.com/gorilla/mux"
	"github.com/kagenti/kagenti/internal/backend/envoy"
	"github.com/kagenti/kagenti/internal/keycloak"
	"github.com/spf13/viper"
)

// Build-time variables
var (
	version = "dev"
	commit  = "unknown"
	date    = "unknown"
)

// Logger for Backend
var backendLogger *slog.Logger

func init() {
	// Log to stdout for Kubernetes
	backendLogger = slog.New(slog.NewTextHandler(os.Stdout, &slog.HandlerOptions{
		Level: slog.LevelInfo,
	}))
}

// Config holds the service configuration
type Config struct {
	Port           int    `mapstructure:"port"`
	AIAgentURL     string `mapstructure:"aiagent_url"`
	DemoPagePath   string `mapstructure:"demo_page_path"`
	KeycloakURL    string `mapstructure:"keycloak_url"`
	KeycloakRealm  string `mapstructure:"keycloak_realm"`
	TokenBrokerURL string `mapstructure:"token_broker_url"`
}

func main() {
	// Log version to verify code deployment
	backendLogger.Info("Backend starting",
		"version", version,
		"commit", commit,
		"build_time", date)

	// Load configuration
	viper.SetConfigName("backend-config")
	viper.SetConfigType("yaml")
	viper.AddConfigPath("/config") // Kubernetes ConfigMap mount
	viper.AddConfigPath(".")
	viper.AddConfigPath("./cmd/backend")

	// Allow environment variables to override config
	viper.AutomaticEnv()

	if err := viper.ReadInConfig(); err != nil {
		backendLogger.Error("Error reading config file", "error", err)
		os.Exit(1)
	}

	var cfg Config
	if err := viper.Unmarshal(&cfg); err != nil {
		backendLogger.Error("Error unmarshaling config", "error", err)
		os.Exit(1)
	}

	// Validate configuration
	if cfg.Port == 0 {
		cfg.Port = 8187
	}
	if cfg.AIAgentURL == "" {
		cfg.AIAgentURL = "http://localhost:8185"
	}
	if cfg.KeycloakURL == "" {
		cfg.KeycloakURL = "http://keycloak-service.keycloak.svc.cluster.local:8080"
	}
	if cfg.KeycloakRealm == "" {
		cfg.KeycloakRealm = "kagenti"
	}
	if cfg.TokenBrokerURL == "" {
		cfg.TokenBrokerURL = "http://localhost:8186"
	}

	// Initialize Keycloak client
	keycloakClient := keycloak.NewClient(cfg.KeycloakURL, cfg.KeycloakRealm)
	backendLogger.Info("Keycloak client initialized",
		"url", cfg.KeycloakURL,
		"realm", cfg.KeycloakRealm)

	// Initialize envoy components
	sessionManager := envoy.NewSessionManager(cfg.TokenBrokerURL)
	jobManager := envoy.NewJobManager(backendLogger)
	sessionManager.SetJobManager(jobManager)
	handler := envoy.NewHandler(sessionManager, jobManager, keycloakClient, cfg.AIAgentURL)

	backendLogger.Info("Backend service starting",
		"port", cfg.Port,
		"aiagent_url", cfg.AIAgentURL,
		"token_broker_url", cfg.TokenBrokerURL)

	// Setup HTTP server with gorilla/mux router
	r := mux.NewRouter()
	r.Use(corsMiddleware)
	r.Use(loggingMiddleware)

	// Register envoy handler routes
	r.HandleFunc("/task", handler.HandleTask).Methods("POST", "OPTIONS")
	r.HandleFunc("/job/{id}", handler.HandleJobStatus).Methods("GET", "OPTIONS")
	r.HandleFunc("/callback", handler.HandleOAuthCallback).Methods("GET", "OPTIONS")
	r.HandleFunc("/events", handler.HandleEvents).Methods("GET", "OPTIONS")
	r.HandleFunc("/session/end", handler.HandleEndSession).Methods("POST", "OPTIONS")

	// Health check endpoint
	r.HandleFunc("/health", func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusOK)
		w.Write([]byte("OK"))
	}).Methods("GET")

	// Serve demo page if configured
	if cfg.DemoPagePath != "" {
		r.HandleFunc("/demo", func(w http.ResponseWriter, r *http.Request) {
			w.Header().Set("Cache-Control", "no-cache, no-store, must-revalidate")
			w.Header().Set("Pragma", "no-cache")
			w.Header().Set("Expires", "0")
			http.ServeFile(w, r, cfg.DemoPagePath)
		}).Methods("GET")
		backendLogger.Info("Demo page registered", "path", cfg.DemoPagePath)
	}

	addr := fmt.Sprintf(":%d", cfg.Port)
	backendLogger.Info("Backend service ready",
		"address", addr,
		"demo_url", fmt.Sprintf("http://localhost:%d/demo", cfg.Port))

	backendLogger.Info("Backend Service starting",
		"port", cfg.Port,
		"architecture", fmt.Sprintf("Browser → Backend:%d → AI Agent:%s → MCP Server", cfg.Port, cfg.AIAgentURL),
		"demo_url", fmt.Sprintf("http://localhost:%d/demo", cfg.Port))

	if err := http.ListenAndServe(addr, r); err != nil {
		backendLogger.Error("Server failed", "error", err)
		os.Exit(1)
	}
}

// corsMiddleware adds CORS headers
func corsMiddleware(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Access-Control-Allow-Origin", "*")
		w.Header().Set("Access-Control-Allow-Methods", "GET, POST, DELETE, OPTIONS")
		w.Header().Set("Access-Control-Allow-Headers", "Content-Type, Authorization")

		if r.Method == "OPTIONS" {
			w.WriteHeader(http.StatusOK)
			return
		}

		next.ServeHTTP(w, r)
	})
}

// loggingMiddleware logs HTTP requests
func loggingMiddleware(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		backendLogger.Info("HTTP request",
			"method", r.Method,
			"path", r.URL.Path,
			"remote_addr", r.RemoteAddr)
		next.ServeHTTP(w, r)
	})
}

// Made with Bob
