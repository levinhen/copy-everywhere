package config

import (
	"os"
	"strconv"
)

type Config struct {
	AccessToken    string
	Port           string
	StoragePath    string
	MaxClipSizeMB int
	TTLHours       int
}

func Load() *Config {
	return &Config{
		AccessToken:    getEnv("ACCESS_TOKEN", ""),
		Port:           getEnv("PORT", "8080"),
		StoragePath:    getEnv("STORAGE_PATH", "./data"),
		MaxClipSizeMB: getEnvInt("MAX_CLIP_SIZE_MB", 500),
		TTLHours:       getEnvInt("TTL_HOURS", 1),
	}
}

func getEnv(key, fallback string) string {
	if v := os.Getenv(key); v != "" {
		return v
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
