package parser

import (
	"encoding/base64"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"strconv"
	"strings"

	"sub-store/models"
)

// FetchAndParse fetches a subscription URL, base64-decodes the body,
// and parses each URI line into a models.Node.
func FetchAndParse(subURL string) ([]models.Node, error) {
	resp, err := http.Get(subURL)
	if err != nil {
		return nil, fmt.Errorf("fetch subscription: %w", err)
	}
	defer resp.Body.Close()

	if resp.StatusCode != http.StatusOK {
		return nil, fmt.Errorf("unexpected status %d from %s", resp.StatusCode, subURL)
	}

	body, err := io.ReadAll(resp.Body)
	if err != nil {
		return nil, fmt.Errorf("read body: %w", err)
	}

	// Try standard base64 first, then URL-safe base64.
	decoded, err := base64.StdEncoding.DecodeString(strings.TrimSpace(string(body)))
	if err != nil {
		decoded, err = base64.URLEncoding.DecodeString(strings.TrimSpace(string(body)))
		if err != nil {
			// If it's not base64 at all, treat body as plain text.
			decoded = body
		}
	}

	var nodes []models.Node
	lines := strings.Split(strings.TrimSpace(string(decoded)), "\n")
	for _, line := range lines {
		line = strings.TrimSpace(line)
		if line == "" {
			continue
		}

		node, err := parseURI(line)
		if err != nil {
			continue // skip unparseable lines
		}
		nodes = append(nodes, *node)
	}
	return nodes, nil
}

// --- URI parsers ---

func parseURI(raw string) (*models.Node, error) {
	switch {
	case strings.HasPrefix(raw, "vmess://"):
		return parseVmess(raw)
	case strings.HasPrefix(raw, "vless://"):
		return parseVless(raw)
	case strings.HasPrefix(raw, "trojan://"):
		return parseTrojan(raw)
	case strings.HasPrefix(raw, "ss://"):
		return parseSS(raw)
	case strings.HasPrefix(raw, "hysteria2://") || strings.HasPrefix(raw, "hy2://"):
		return parseHysteria2(raw)
	case strings.HasPrefix(raw, "tuic://"):
		return parseTUIC(raw)
	default:
		return nil, fmt.Errorf("unsupported scheme: %s", raw)
	}
}

// generateID returns a simple deterministic pseudo-UUID based on the raw URI.
func generateID(raw string) string {
	h := fmt.Sprintf("%016x", fnv64(raw))
	return fmt.Sprintf("%s-%s-%s-%s-%s", h[:8], h[8:12], h[12:16], h[:4], h[4:12])
}

// fnv64 is a simple FNV-1a hash for deterministic IDs.
func fnv64(s string) uint64 {
	var h uint64 = 14695981039346656037
	for i := 0; i < len(s); i++ {
		h ^= uint64(s[i])
		h *= 1099511628211
	}
	return h
}

// --- vmess:// (base64-encoded JSON) ---

type vmessInfo struct {
	Ps   string `json:"ps"`
	Add  string `json:"add"`
	Port int    `json:"port"`
	ID   string `json:"id"`
	Net  string `json:"net"`
	TLS  string `json:"tls"`
	SNI  string `json:"sni"`
	Alpn string `json:"alpn"`
	Host string `json:"host"`
	Path string `json:"path"`
}

func parseVmess(raw string) (*models.Node, error) {
	b64 := strings.TrimPrefix(raw, "vmess://")
	// try standard then URL-safe
	data, err := base64.StdEncoding.DecodeString(b64)
	if err != nil {
		data, err = base64.URLEncoding.DecodeString(b64)
		if err != nil {
			data, err = base64.RawStdEncoding.DecodeString(b64)
			if err != nil {
				data, err = base64.RawURLEncoding.DecodeString(b64)
				if err != nil {
					return nil, fmt.Errorf("vmess base64 decode: %w", err)
				}
			}
		}
	}

	var info vmessInfo
	if err := json.Unmarshal(data, &info); err != nil {
		return nil, fmt.Errorf("vmess json: %w", err)
	}

	transport := info.Net
	if transport == "" {
		transport = "tcp"
	}

	tls := info.TLS == "tls"

	alpn := splitNonEmpty(info.Alpn, ",")

	node := &models.Node{
		ID:        generateID(raw),
		Name:      info.Ps,
		Type:      "vmess",
		Server:    info.Add,
		Port:      info.Port,
		UUID:      info.ID,
		Transport: transport,
		TLS:       tls,
		SNI:       info.SNI,
		Alpn:      alpn,
		RawURI:    raw,
		Extra:     make(map[string]string),
	}
	if info.Host != "" {
		node.Extra["host"] = info.Host
	}
	if info.Path != "" {
		node.Extra["path"] = info.Path
	}
	return node, nil
}

// --- vless://uuid@server:port?params#name ---

func parseVless(raw string) (*models.Node, error) {
	name := ""
	uri := raw
	if idx := strings.LastIndex(raw, "#"); idx != -1 {
		name, _ = url.PathUnescape(raw[idx+1:])
		uri = raw[:idx]
	}

	parsed, err := url.Parse(uri)
	if err != nil {
		return nil, fmt.Errorf("vless parse: %w", err)
	}

	port, _ := strconv.Atoi(parsed.Port())
	q := parsed.Query()

	node := &models.Node{
		ID:        generateID(raw),
		Name:      name,
		Type:      "vless",
		Server:    parsed.Hostname(),
		Port:      port,
		UUID:      parsed.User.Username(),
		Transport: q.Get("type"),
		TLS:       q.Get("security") == "tls",
		SNI:       q.Get("sni"),
		Alpn:      splitNonEmpty(q.Get("alpn"), ","),
		RawURI:    raw,
		Extra:     make(map[string]string),
	}
	if node.Transport == "" {
		node.Transport = "tcp"
	}
	return node, nil
}

// --- trojan://pass@server:port?params#name ---

func parseTrojan(raw string) (*models.Node, error) {
	name := ""
	uri := raw
	if idx := strings.LastIndex(raw, "#"); idx != -1 {
		name, _ = url.PathUnescape(raw[idx+1:])
		uri = raw[:idx]
	}

	parsed, err := url.Parse(uri)
	if err != nil {
		return nil, fmt.Errorf("trojan parse: %w", err)
	}

	port, _ := strconv.Atoi(parsed.Port())
	q := parsed.Query()

	node := &models.Node{
		ID:        generateID(raw),
		Name:      name,
		Type:      "trojan",
		Server:    parsed.Hostname(),
		Port:      port,
		Password:  parsed.User.Username(),
		Transport: q.Get("type"),
		TLS:       true, // trojan always uses TLS
		SNI:       q.Get("sni"),
		Alpn:      splitNonEmpty(q.Get("alpn"), ","),
		RawURI:    raw,
		Extra:     make(map[string]string),
	}
	if node.Transport == "" {
		node.Transport = "tcp"
	}
	return node, nil
}

// --- ss://base64(method:password)@server:port#name ---

func parseSS(raw string) (*models.Node, error) {
	name := ""
	uri := raw
	if idx := strings.LastIndex(raw, "#"); idx != -1 {
		name, _ = url.PathUnescape(raw[idx+1:])
		uri = raw[:idx]
	}

	// Remove "ss://"
	b64part := strings.TrimPrefix(uri, "ss://")

	var userInfo string
	var hostPort string

	// Format can be: ss://base64(method:pass)@server:port  OR  ss://base64whole
	if idx := strings.Index(b64part, "@"); idx != -1 {
		// Split into userinfo@host
		b64user := b64part[:idx]
		hostPort = b64part[idx+1:]

		decoded, err := base64DecodeAny(b64user)
		if err != nil {
			return nil, fmt.Errorf("ss base64 decode userinfo: %w", err)
		}
		userInfo = string(decoded)
	} else {
		// Entire thing is base64
		decoded, err := base64DecodeAny(b64part)
		if err != nil {
			return nil, fmt.Errorf("ss base64 decode: %w", err)
		}
		parts := strings.SplitN(string(decoded), "@", 2)
		if len(parts) != 2 {
			return nil, fmt.Errorf("ss format invalid: %s", string(decoded))
		}
		userInfo = parts[0]
		hostPort = parts[1]
	}

	// Parse method:password
	methodPass := strings.SplitN(userInfo, ":", 2)
	method := methodPass[0]
	password := ""
	if len(methodPass) > 1 {
		password = methodPass[1]
	}

	// Parse host:port
	host, portStr, err := netSplitHostPort(hostPort)
	if err != nil {
		return nil, fmt.Errorf("ss host:port: %w", err)
	}
	port, _ := strconv.Atoi(portStr)

	node := &models.Node{
		ID:      generateID(raw),
		Name:    name,
		Type:    "ss",
		Server:  host,
		Port:    port,
		Password: password,
		TLS:     false,
		RawURI:  raw,
		Extra:   map[string]string{"method": method},
	}
	return node, nil
}

// --- hysteria2://pass@server:port?params#name ---

func parseHysteria2(raw string) (*models.Node, error) {
	name := ""
	uri := raw
	if idx := strings.LastIndex(raw, "#"); idx != -1 {
		name, _ = url.PathUnescape(raw[idx+1:])
		uri = raw[:idx]
	}

	// Normalize scheme for url.Parse
	normalized := strings.Replace(uri, "hy2://", "hysteria2://", 1)

	parsed, err := url.Parse(normalized)
	if err != nil {
		return nil, fmt.Errorf("hysteria2 parse: %w", err)
	}

	port, _ := strconv.Atoi(parsed.Port())
	q := parsed.Query()

	node := &models.Node{
		ID:       generateID(raw),
		Name:     name,
		Type:     "hysteria2",
		Server:   parsed.Hostname(),
		Port:     port,
		Password: parsed.User.Username(),
		TLS:      true,
		SNI:      q.Get("sni"),
		Alpn:     splitNonEmpty(q.Get("alpn"), ","),
		RawURI:   raw,
		Extra:    make(map[string]string),
	}
	if obfs := q.Get("obfs"); obfs != "" {
		node.Extra["obfs"] = obfs
		if obsp := q.Get("obfs-password"); obsp != "" {
			node.Extra["obfs-password"] = obsp
		}
	}
	return node, nil
}

// --- tuic://uuid:pass@server:port?params#name ---

func parseTUIC(raw string) (*models.Node, error) {
	name := ""
	uri := raw
	if idx := strings.LastIndex(raw, "#"); idx != -1 {
		name, _ = url.PathUnescape(raw[idx+1:])
		uri = raw[:idx]
	}

	parsed, err := url.Parse(uri)
	if err != nil {
		return nil, fmt.Errorf("tuic parse: %w", err)
	}

	port, _ := strconv.Atoi(parsed.Port())
	q := parsed.Query()

	// Userinfo is uuid:password
	userStr := parsed.User.Username()
	pass, _ := parsed.User.Password()
	if pass == "" {
		// Try splitting uuid:password from username
		parts := strings.SplitN(userStr, ":", 2)
		if len(parts) == 2 {
			userStr = parts[0]
			pass = parts[1]
		}
	}

	node := &models.Node{
		ID:       generateID(raw),
		Name:     name,
		Type:     "tuic",
		Server:   parsed.Hostname(),
		Port:     port,
		Password: pass,
		UUID:     userStr,
		TLS:      true,
		SNI:      q.Get("sni"),
		Alpn:     splitNonEmpty(q.Get("alpn"), ","),
		RawURI:   raw,
		Extra:    make(map[string]string),
	}
	if congestion := q.Get("congestion_control"); congestion != "" {
		node.Extra["congestion_control"] = congestion
	}
	if udpRelay := q.Get("udp_relay_mode"); udpRelay != "" {
		node.Extra["udp_relay_mode"] = udpRelay
	}
	return node, nil
}

// --- helpers ---

func base64DecodeAny(s string) ([]byte, error) {
	// Try standard, URL-safe, raw-std, raw-url in order.
	if d, err := base64.StdEncoding.DecodeString(s); err == nil {
		return d, nil
	}
	if d, err := base64.URLEncoding.DecodeString(s); err == nil {
		return d, nil
	}
	if d, err := base64.RawStdEncoding.DecodeString(s); err == nil {
		return d, nil
	}
	return base64.RawURLEncoding.DecodeString(s)
}

func splitNonEmpty(s, sep string) []string {
	if s == "" {
		return nil
	}
	parts := strings.Split(s, sep)
	out := make([]string, 0, len(parts))
	for _, p := range parts {
		p = strings.TrimSpace(p)
		if p != "" {
			out = append(out, p)
		}
	}
	if len(out) == 0 {
		return nil
	}
	return out
}

// netSplitHostPort wraps splitting to handle IPv6 brackets gracefully.
func netSplitHostPort(hostport string) (host, port string, err error) {
	// url.Parse can handle this; use a lightweight approach.
	if strings.HasPrefix(hostport, "[") {
		// IPv6
		end := strings.LastIndex(hostport, "]")
		if end == -1 {
			return "", "", fmt.Errorf("invalid host:port: %s", hostport)
		}
		host = hostport[1:end]
		rest := hostport[end+1:]
		if strings.HasPrefix(rest, ":") {
			port = rest[1:]
		}
	} else {
		parts := strings.SplitN(hostport, ":", 2)
		host = parts[0]
		if len(parts) > 1 {
			port = parts[1]
		}
	}
	if host == "" || port == "" {
		return "", "", fmt.Errorf("invalid host:port: %s", hostport)
	}
	return host, port, nil
}
