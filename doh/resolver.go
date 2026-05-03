package doh

import (
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"sync"
	"time"
)

// Resolver performs DNS-over-HTTPS resolution using one or more DoH servers.
// It caches results for a configurable TTL and is safe for concurrent use.
type Resolver struct {
	servers []string // DoH server URLs ("cloudflare" or "google" resolved at construction)
	client  *http.Client
	cache   map[string]cacheEntry
	mu      sync.RWMutex
	ttl     time.Duration
}

type cacheEntry struct {
	ips     []string
	expires time.Time
}

// DNSResponse represents the JSON response from both Cloudflare and Google DoH.
type DNSResponse struct {
	Answer []struct {
		Data string `json:"data"`
	} `json:"Answer"`
}

// NewResolver creates a new DoH resolver.
// servers: list of server identifiers — currently "cloudflare" and "google" are supported.
// engine: unused but reserved for future selection logic.
func NewResolver(servers []string, engine string) *Resolver {
	r := &Resolver{
		client: &http.Client{Timeout: 10 * time.Second},
		cache:  make(map[string]cacheEntry),
		ttl:    5 * time.Minute,
	}

	for _, s := range servers {
		switch s {
		case "cloudflare":
			r.servers = append(r.servers, "https://cloudflare-dns.com/dns-query")
		case "google":
			r.servers = append(r.servers, "https://dns.google/resolve")
		default:
			// Treat as a raw URL (allows custom servers).
			r.servers = append(r.servers, s)
		}
	}

	if len(r.servers) == 0 {
		// Fallback to Cloudflare.
		r.servers = []string{"https://cloudflare-dns.com/dns-query"}
	}

	return r
}

// Resolve resolves the domain and returns all A-record IP addresses.
// It tries each configured DoH server in order until one succeeds.
func (r *Resolver) Resolve(domain string) ([]string, error) {
	r.mu.RLock()
	if entry, ok := r.cache[domain]; ok && time.Now().Before(entry.expires) {
		r.mu.RUnlock()
		return entry.ips, nil
	}
	r.mu.RUnlock()

	var lastErr error
	for _, server := range r.servers {
		ips, err := r.query(server, domain)
		if err != nil {
			lastErr = err
			continue
		}

		// Cache the result.
		r.mu.Lock()
		r.cache[domain] = cacheEntry{
			ips:     ips,
			expires: time.Now().Add(r.ttl),
		}
		r.mu.Unlock()

		return ips, nil
	}

	if lastErr != nil {
		return nil, fmt.Errorf("doh: all servers failed for %s: %w", domain, lastErr)
	}
	return nil, fmt.Errorf("doh: no servers configured")
}

// ResolveFirst returns the first resolved IP address for the domain.
func (r *Resolver) ResolveFirst(domain string) (string, error) {
	ips, err := r.Resolve(domain)
	if err != nil {
		return "", err
	}
	if len(ips) == 0 {
		return "", fmt.Errorf("doh: no A records for %s", domain)
	}
	return ips[0], nil
}

// Test resolves "cloudflare.com" and returns an error if resolution fails.
func (r *Resolver) Test() error {
	ips, err := r.Resolve("cloudflare.com")
	if err != nil {
		return fmt.Errorf("doh test failed: %w", err)
	}
	if len(ips) == 0 {
		return fmt.Errorf("doh test: no results for cloudflare.com")
	}
	return nil
}

// query sends a DNS query to a specific DoH server for the given domain.
func (r *Resolver) query(server, domain string) ([]string, error) {
	reqURL := fmt.Sprintf("%s?name=%s&type=A", server, domain)

	req, err := http.NewRequest(http.MethodGet, reqURL, nil)
	if err != nil {
		return nil, fmt.Errorf("doh: create request: %w", err)
	}
	req.Header.Set("Accept", "application/dns-json")

	resp, err := r.client.Do(req)
	if err != nil {
		return nil, fmt.Errorf("doh: request to %s: %w", server, err)
	}
	defer resp.Body.Close()

	if resp.StatusCode != http.StatusOK {
		return nil, fmt.Errorf("doh: %s returned status %d", server, resp.StatusCode)
	}

	body, err := io.ReadAll(resp.Body)
	if err != nil {
		return nil, fmt.Errorf("doh: read response: %w", err)
	}

	var dnsResp DNSResponse
	if err := json.Unmarshal(body, &dnsResp); err != nil {
		return nil, fmt.Errorf("doh: parse response from %s: %w", server, err)
	}

	var ips []string
	for _, ans := range dnsResp.Answer {
		if ans.Data != "" {
			ips = append(ips, ans.Data)
		}
	}
	if len(ips) == 0 {
		return nil, fmt.Errorf("doh: no A records in response from %s for %s", server, domain)
	}

	return ips, nil
}
