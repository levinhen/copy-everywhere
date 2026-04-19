package config

import (
	"crypto/rand"
	"encoding/hex"
	"fmt"
	"os"
	"path/filepath"
	"strconv"
	"strings"
)

type Config struct {
	AuthEnabled             bool
	AccessToken             string
	Port                    string
	BindAddress             string
	StoragePath             string
	MaxClipSizeMB           int
	TTLHours                int
	CleanupIntervalSeconds  int
	TargetedFallbackSeconds int
}

func Load() *Config {
	return &Config{
		AuthEnabled:             getEnvBool("AUTH_ENABLED", false),
		AccessToken:             getEnv("ACCESS_TOKEN", ""),
		Port:                    getEnv("PORT", "8080"),
		BindAddress:             getEnv("BIND_ADDRESS", "0.0.0.0"),
		StoragePath:             getEnv("STORAGE_PATH", "./data"),
		MaxClipSizeMB:           getEnvInt("MAX_CLIP_SIZE_MB", 500),
		TTLHours:                getEnvInt("TTL_HOURS", 1),
		CleanupIntervalSeconds:  getEnvInt("CLEANUP_INTERVAL_SECONDS", 30),
		TargetedFallbackSeconds: getEnvInt("TARGETED_FALLBACK_SECONDS", 30),
	}
}

func getEnv(key, fallback string) string {
	if v := os.Getenv(key); v != "" {
		return v
	}
	return fallback
}

func getEnvBool(key string, fallback bool) bool {
	if v := os.Getenv(key); v != "" {
		return strings.EqualFold(v, "true") || v == "1"
	}
	return fallback
}

func getEnvInt(key string, fallback int) int {
	if v := os.Getenv(key); v != "" {
		if i, err := strconv.Atoi(v); err == nil {
			return i
		}
	}
	return fallback
}

func LoadOrCreateServerID(storagePath string) (string, error) {
	if err := os.MkdirAll(storagePath, 0755); err != nil {
		return "", fmt.Errorf("create storage dir: %w", err)
	}

	serverIDPath := filepath.Join(storagePath, "server_id")
	if data, err := os.ReadFile(serverIDPath); err == nil {
		serverID := strings.TrimSpace(string(data))
		if serverID != "" {
			return serverID, nil
		}
	} else if !os.IsNotExist(err) {
		return "", fmt.Errorf("read server_id: %w", err)
	}

	serverID, err := generateServerID()
	if err != nil {
		return "", err
	}

	tempPath := serverIDPath + ".tmp"
	if err := os.WriteFile(tempPath, []byte(serverID+"\n"), 0644); err != nil {
		return "", fmt.Errorf("write temp server_id: %w", err)
	}
	if err := os.Rename(tempPath, serverIDPath); err != nil {
		return "", fmt.Errorf("persist server_id: %w", err)
	}

	return serverID, nil
}

func generateServerID() (string, error) {
	buf := make([]byte, 16)
	if _, err := rand.Read(buf); err != nil {
		return "", fmt.Errorf("generate server_id: %w", err)
	}
	return hex.EncodeToString(buf), nil
}
