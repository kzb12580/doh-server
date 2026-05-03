package config

import (
	"encoding/json"
	"os"
	"path/filepath"
)

type Config struct {
	DataDir    string   `json:"data_dir"`
	LogLevel   string   `json:"log_level"`
	DOHServers []string `json:"doh_servers"`
	DOHEngine  string   `json:"doh_engine"` // "cloudflare" or "google"
}

func Default() *Config {
	return &Config{
		DataDir:    "data",
		LogLevel:   "info",
		DOHServers: []string{"https://cloudflare-dns.com/dns-query", "https://dns.google/dns-query"},
		DOHEngine:  "cloudflare",
	}
}

func Load(path string) (*Config, error) {
	data, err := os.ReadFile(path)
	if err != nil {
		return nil, err
	}
	cfg := Default()
	if err := json.Unmarshal(data, cfg); err != nil {
		return nil, err
	}
	return cfg, nil
}

func (c *Config) Save(path string) error {
	os.MkdirAll(filepath.Dir(path), 0755)
	data, err := json.MarshalIndent(c, "", "  ")
	if err != nil {
		return err
	}
	return os.WriteFile(path, data, 0644)
}
