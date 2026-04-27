package main

import (
	"context"
	"fmt"
	"log/slog"
	"net/http"
	"os"
	"os/signal"
	"syscall"
	"time"

	"github.com/go-chi/chi/v5"
	"github.com/go-chi/chi/v5/middleware"
	"github.com/kagenti/kagenti/internal/tokenbroker/api"
	"github.com/kagenti/kagenti/internal/tokenbroker/cache"
	"github.com/kagenti/kagenti/internal/tokenbroker/core"
	"github.com/kagenti/kagenti/internal/tokenbroker/oauthflow"
	"github.com/kagenti/kagenti/internal/tokenbroker/session"
	"github.com/spf13/viper"
)

// Config holds the token broker configuration
type Config struct {
	Port               int           `mapstructure:"port"`
	CallbackURL        string        `mapstructure:"callback_url"`
	SessionTimeout     time.Duration `mapstructure:"session_timeout"`
	MaxSessionsPerUser int           `mapstructure:"max_sessions_per_user"`
	TokenWaitTimeout   time.Duration `mapstructure:"token_wait_timeout"`
	TokenCacheDuration time.Duration `mapstructure:"token_cache_duration"`
	TokenCacheMaxSize  int           `mapstructure:"token_cache_max_size"`
}

func main() {
	// Initialize logger
	logger := slog.New(slog.NewJSONHandler(os.Stdout, &slog.HandlerOptions{
		Level: slog.LevelInfo,
	}))
	slog.SetDefault(logger)

	// Load configuration
	viper.SetConfigName("token-broker-config")
	viper.SetConfigType("yaml")
	viper.AddConfigPath("/config")
	viper.AddConfigPath(".")
	viper.AutomaticEnv()

	// Set defaults
	viper.SetDefault("port", 8190)
	viper.SetDefault("callback_url", "http://localhost:8187/callback")
	viper.SetDefault("session_timeout", 60*time.Minute)
	viper.SetDefault("max_sessions_per_user", 5)
	viper.SetDefault("token_wait_timeout", 5*time.Minute)
	viper.SetDefault("token_cache_duration", 50*time.Minute)
	viper.SetDefault("token_cache_max_size", 1000)

	if err := viper.ReadInConfig(); err != nil {
		if _, ok := err.(viper.ConfigFileNotFoundError); !ok {
			logger.Error("Error reading config file", "error", err)
			os.Exit(1)
		}
		logger.Info("No config file found, using defaults")
	}

	var cfg Config
	if err := viper.Unmarshal(&cfg); err != nil {
		logger.Error("Error unmarshaling config", "error", err)
		os.Exit(1)
	}

	logger.Info("Configuration loaded",
		"listen_port", cfg.Port,
		"callback_url", cfg.CallbackURL,
		"session_timeout", cfg.SessionTimeout,
		"max_sessions_per_user", cfg.MaxSessionsPerUser,
		"token_wait_timeout", cfg.TokenWaitTimeout)

	// Initialize components
	clock := &core.RealClock{}
	sessionManager := session.NewSessionManager(
		cfg.SessionTimeout,
		cfg.MaxSessionsPerUser,
		clock,
		logger,
	)

	tokenCache := cache.NewTokenCache(clock)

	discoverer := oauthflow.NewDiscoverer(logger)
	tokenExchanger := oauthflow.NewTokenExchanger(logger)

	broker := core.NewTokenBroker(
		sessionManager,
		tokenCache,
		discoverer,
		tokenExchanger,
		cfg.CallbackURL,
		cfg.TokenWaitTimeout,
		logger,
	)

	handler := api.NewHandler(broker, sessionManager, logger)

	// Setup HTTP server
	r := chi.NewRouter()
	r.Use(middleware.RequestID)
	r.Use(middleware.RealIP)
	r.Use(middleware.Logger)
	r.Use(middleware.Recoverer)

	// Register routes
	r.Post("/sessions", handler.HandleCreateSession)
	r.Post("/sessions/{session_key}/events", handler.HandleEvents)
	r.Post("/sessions/{session_key}/end", handler.HandleEndSession)
	r.Get("/sessions/{session_key}/token", handler.HandleGetToken)

	addr := fmt.Sprintf(":%d", cfg.Port)
	server := &http.Server{
		Addr:    addr,
		Handler: r,
	}

	// Start server in goroutine
	go func() {
		logger.Info("Token Broker listening", "address", addr)
		if err := server.ListenAndServe(); err != nil && err != http.ErrServerClosed {
			logger.Error("Server error", "error", err)
			os.Exit(1)
		}
	}()

	// Wait for interrupt signal
	sigChan := make(chan os.Signal, 1)
	signal.Notify(sigChan, os.Interrupt, syscall.SIGTERM)
	<-sigChan

	logger.Info("Shutting down server...")

	// Shutdown gracefully
	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()

	if err := server.Shutdown(ctx); err != nil {
		logger.Error("Server shutdown error", "error", err)
	}

	sessionManager.Shutdown()
	logger.Info("Server stopped")
}

// Made with Bob
