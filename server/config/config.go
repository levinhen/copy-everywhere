package config

import (
	"os"
	"strconv"
	"strings"
)

type Config struct {
	AuthEnabled            bool
	AccessToken            string
	Port                   string
	StoragePath            string
	MaxClipSizeMB          int
	TTLHours               int
	CleanupIntervalSeconds int
}

func Load() *Config {
	return &Config{
		AuthEnabled:            getEnvBool("AUTH_ENABLED", false),
		AccessToken:            getEnv("ACCESS_TOKEN", ""),
		Port:                   getEnv("PORT", "8080"),
		StoragePath:            getEnv("STORAGE_PATH", "./data"),
		MaxClipSizeMB:          getEnvInt("MAX_CLIP_SIZE_MB", 500),
		TTLHours:               getEnvInt("TTL_HOURS", 1),
		CleanupIntervalSeconds: getEnvInt("CLEANUP_INTERVAL_SECONDS", 30),
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
