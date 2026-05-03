package converter

import (
	"encoding/json"
	"fmt"
	"net"
	"strings"

	"sub-store/models"

	"gopkg.in/yaml.v3"
)

// Resolver resolves a domain to its first IP address.
type Resolver interface {
	ResolveFirst(domain string) (string, error)
}

// resolveServer resolves a domain to IP if resolver is available.
// Returns the resolved IP (or original host if not resolvable) and the
// original hostname to use as SNI.
func resolveServer(server string, resolver Resolver) (ip, sni string) {
	if resolver == nil {
		return server, server
	}
	// If already an IP, nothing to resolve.
	if net.ParseIP(server) != nil {
		return server, server
	}
	sni = server
	resolved, err := resolver.ResolveFirst(server)
	if err != nil || resolved == "" {
		return server, server
	}
	return resolved, sni
}

// ──────────────────────────────────────────────────────────────────────────────
// Clash / Mihomo YAML
// ──────────────────────────────────────────────────────────────────────────────

type clashConfig struct {
	MixedPort int              `yaml:"mixed-port"`
	AllowLan  bool             `yaml:"allow-lan"`
	Mode      string           `yaml:"mode"`
	LogLevel  string           `yaml:"log-level"`
	DNS       clashDNS         `yaml:"dns"`
	Proxies   []any            `yaml:"proxies,omitempty"`
	ProxyGrps []any            `yaml:"proxy-groups"`
	Rules     []string         `yaml:"rules"`
}

type clashDNS struct {
	Enable        bool     `yaml:"enable"`
	IPv6          bool     `yaml:"ipv6"`
	DefaultNameserver []string `yaml:"default-nameserver"`
	EnhancedMode  string   `yaml:"enhanced-mode"`
	Nameserver    []string `yaml:"nameserver"`
	Fallback      []string `yaml:"fallback"`
	FallbackFilter any     `yaml:"fallback-filter,omitempty"`
}

// GenerateClash produces a Clash/Mihomo YAML config from the given nodes.
func GenerateClash(nodes []models.Node, resolver Resolver) ([]byte, error) {
	if len(nodes) == 0 {
		return nil, fmt.Errorf("converter: no nodes provided")
	}

	var proxies []any
	var names []string

	for _, n := range nodes {
		ip, sni := resolveServer(n.Server, resolver)
		name := n.Name

		switch strings.ToLower(n.Type) {
		case "vmess":
			p := map[string]any{
				"name":       name,
				"type":       "vmess",
				"server":     ip,
				"port":       n.Port,
				"uuid":       n.UUID,
				"alterId":    0,
				"cipher":     "auto",
				"tls":        n.TLS,
			}
			if n.TLS {
				p["servername"] = sni
			}
			if n.Transport != "" {
				p["network"] = n.Transport
			}
			if n.SNI != "" {
				p["servername"] = n.SNI
			}
			applyClashExtra(p, n.Extra)
			proxies = append(proxies, p)

		case "vless":
			p := map[string]any{
				"name":     name,
				"type":     "vless",
				"server":   ip,
				"port":     n.Port,
				"uuid":     n.UUID,
				"tls":      n.TLS,
			}
			if n.TLS {
				p["servername"] = sni
			}
			if n.Transport != "" {
				p["network"] = n.Transport
			}
			if n.SNI != "" {
				p["servername"] = n.SNI
			}
			if len(n.Alpn) > 0 {
				p["alpn"] = n.Alpn
			}
			applyClashExtra(p, n.Extra)
			proxies = append(proxies, p)

		case "trojan":
			p := map[string]any{
				"name":     name,
				"type":     "trojan",
				"server":   ip,
				"port":     n.Port,
				"password": n.Password,
			}
			if sni != "" {
				p["sni"] = sni
			}
			if n.SNI != "" {
				p["sni"] = n.SNI
			}
			if len(n.Alpn) > 0 {
				p["alpn"] = n.Alpn
			}
			if n.Transport != "" {
				p["network"] = n.Transport
			}
			applyClashExtra(p, n.Extra)
			proxies = append(proxies, p)

		case "ss":
			p := map[string]any{
				"name":     name,
				"type":     "ss",
				"server":   ip,
				"port":     n.Port,
				"password": n.Password,
			}
			if cipher, ok := n.Extra["cipher"]; ok {
				p["cipher"] = cipher
			} else {
				p["cipher"] = "aes-128-gcm"
			}
			if n.Plugin != "" {
				p["plugin"] = n.Plugin
				p["plugin-opts"] = n.PluginOpts
			}
			proxies = append(proxies, p)

		case "hysteria2":
			p := map[string]any{
				"name":     name,
				"type":     "hysteria2",
				"server":   ip,
				"port":     n.Port,
				"password": n.Password,
			}
			s := sni
			if n.SNI != "" {
				s = n.SNI
			}
			if s != "" {
				p["sni"] = s
			}
			if len(n.Alpn) > 0 {
				p["alpn"] = n.Alpn
			}
			if up, ok := n.Extra["up"]; ok {
				p["up"] = up
			}
			if down, ok := n.Extra["down"]; ok {
				p["down"] = down
			}
			proxies = append(proxies, p)

		case "tuic":
			p := map[string]any{
				"name":     name,
				"type":     "tuic",
				"server":   ip,
				"port":     n.Port,
				"uuid":     n.UUID,
				"password": n.Password,
			}
			s := sni
			if n.SNI != "" {
				s = n.SNI
			}
			if s != "" {
				p["sni"] = s
			}
			if len(n.Alpn) > 0 {
				p["alpn"] = n.Alpn
			}
			if congestion, ok := n.Extra["congestion-control"]; ok {
				p["congestion-control"] = congestion
			}
			proxies = append(proxies, p)

		default:
			// skip unknown types
			continue
		}
		names = append(names, name)
	}

	if len(names) == 0 {
		return nil, fmt.Errorf("converter: no supported proxy nodes")
	}

	// proxy-groups
	proxyGroups := []any{
		map[string]any{
			"name":    "PROXY",
			"type":    "select",
			"proxies": append([]string{"AUTO"}, names...),
		},
		map[string]any{
			"name":     "AUTO",
			"type":     "url-test",
			"proxies":  names,
			"url":      "https://www.gstatic.com/generate_204",
			"interval": 300,
		},
	}

	cfg := clashConfig{
		MixedPort: 7890,
		AllowLan:  false,
		Mode:      "rule",
		LogLevel:  "info",
		DNS: clashDNS{
			Enable: true,
			IPv6:   false,
			DefaultNameserver: []string{
				"8.8.8.8",
				"1.1.1.1",
			},
			EnhancedMode: "fake-ip",
			Nameserver: []string{
				"https://1.1.1.1/dns-query",
				"https://dns.cloudflare.com/dns-query",
			},
			Fallback: []string{
				"https://dns.google/dns-query",
				"https://1.0.0.1/dns-query",
			},
			FallbackFilter: map[string]any{
				"geoip":     true,
				"geoip-code": "CN",
			},
		},
		Proxies:   proxies,
		ProxyGrps: proxyGroups,
		Rules: []string{
			"GEOIP,CN,DIRECT",
			"MATCH,PROXY",
		},
	}

	out, err := yaml.Marshal(&cfg)
	if err != nil {
		return nil, fmt.Errorf("converter: clash marshal: %w", err)
	}
	return out, nil
}

// applyClashExtra copies extra key-value pairs into a Clash proxy map.
func applyClashExtra(p map[string]any, extra map[string]string) {
	for k, v := range extra {
		if _, exists := p[k]; !exists {
			p[k] = v
		}
	}
}

// ──────────────────────────────────────────────────────────────────────────────
// Sing-box JSON
// ──────────────────────────────────────────────────────────────────────────────

type singBoxConfig struct {
	Inbounds  []any `json:"inbounds"`
	Outbounds []any `json:"outbounds"`
	Route     any   `json:"route"`
}

// GenerateSingBox produces a sing-box JSON config from the given nodes.
func GenerateSingBox(nodes []models.Node, resolver Resolver) ([]byte, error) {
	if len(nodes) == 0 {
		return nil, fmt.Errorf("converter: no nodes provided")
	}

	// mixed inbound
	inbounds := []any{
		map[string]any{
			"type":        "mixed",
			"tag":         "mixed-in",
			"listen":      "127.0.0.1",
			"listen_port": 2080,
		},
	}

	var outbounds []any
	var tags []string

	for _, n := range nodes {
		ip, sni := resolveServer(n.Server, resolver)
		tag := n.Name

		switch strings.ToLower(n.Type) {
		case "vmess":
			ob := map[string]any{
				"type": "vmess",
				"tag":  tag,
				"server": ip,
				"port":   n.Port,
				"uuid":   n.UUID,
			}
			if n.TLS {
				ob["tls"] = singboxTLS(sni, n)
			}
			if n.Transport != "" {
				ob["transport"] = singboxTransport(n)
			}
			outbounds = append(outbounds, ob)

		case "vless":
			ob := map[string]any{
				"type": "vless",
				"tag":  tag,
				"server": ip,
				"port":   n.Port,
				"uuid":   n.UUID,
			}
			if n.TLS {
				ob["tls"] = singboxTLS(sni, n)
			}
			if n.Transport != "" {
				ob["transport"] = singboxTransport(n)
			}
			outbounds = append(outbounds, ob)

		case "trojan":
			ob := map[string]any{
				"type":     "trojan",
				"tag":      tag,
				"server":   ip,
				"port":     n.Port,
				"password": n.Password,
			}
			ob["tls"] = singboxTLS(sni, n)
			if n.Transport != "" {
				ob["transport"] = singboxTransport(n)
			}
			outbounds = append(outbounds, ob)

		case "ss":
			ob := map[string]any{
				"type":     "shadowsocks",
				"tag":      tag,
				"server":   ip,
				"port":     n.Port,
				"password": n.Password,
			}
			if cipher, ok := n.Extra["cipher"]; ok {
				ob["method"] = cipher
			} else {
				ob["method"] = "aes-128-gcm"
			}
			outbounds = append(outbounds, ob)

		case "hysteria2":
			ob := map[string]any{
				"type":     "hysteria2",
				"tag":      tag,
				"server":   ip,
				"port":     n.Port,
				"password": n.Password,
			}
			ob["tls"] = singboxTLS(sni, n)
			if up, ok := n.Extra["up"]; ok {
				ob["up_mbps"] = parseMbps(up)
			}
			if down, ok := n.Extra["down"]; ok {
				ob["down_mbps"] = parseMbps(down)
			}
			outbounds = append(outbounds, ob)

		case "tuic":
			ob := map[string]any{
				"type":     "tuic",
				"tag":      tag,
				"server":   ip,
				"port":     n.Port,
				"uuid":     n.UUID,
				"password": n.Password,
			}
			ob["tls"] = singboxTLS(sni, n)
			if congestion, ok := n.Extra["congestion-control"]; ok {
				ob["congestion_control"] = congestion
			}
			outbounds = append(outbounds, ob)

		default:
			continue
		}
		tags = append(tags, tag)
	}

	if len(tags) == 0 {
		return nil, fmt.Errorf("converter: no supported proxy nodes")
	}

	// direct + dns outbounds
	outbounds = append(outbounds,
		map[string]any{"type": "direct", "tag": "direct"},
		map[string]any{"type": "dns", "tag": "dns-out"},
	)

	route := map[string]any{
		"rules": []any{
			map[string]any{
				"protocol": "dns",
				"outbound": "dns-out",
			},
			map[string]any{
				"geoip":    "cn",
				"outbound": "direct",
			},
		},
		"final": tags[0], // use first node as default; overridden by group
		"auto_detect_interface": true,
	}

	cfg := singBoxConfig{
		Inbounds:  inbounds,
		Outbounds: outbounds,
		Route:     route,
	}

	out, err := json.MarshalIndent(cfg, "", "  ")
	if err != nil {
		return nil, fmt.Errorf("converter: sing-box marshal: %w", err)
	}
	return out, nil
}

// singboxTLS builds a sing-box TLS object.
func singboxTLS(sni string, n models.Node) map[string]any {
	t := map[string]any{
		"enabled": true,
	}
	serverName := sni
	if n.SNI != "" {
		serverName = n.SNI
	}
	if serverName != "" {
		t["server_name"] = serverName
	}
	if len(n.Alpn) > 0 {
		t["alpn"] = n.Alpn
	}
	return t
}

// singboxTransport builds a sing-box transport object from a node.
func singboxTransport(n models.Node) map[string]any {
	t := map[string]any{
		"type": n.Transport,
	}
	if host, ok := n.Extra["host"]; ok {
		t["host"] = host
	}
	if path, ok := n.Extra["path"]; ok {
		t["path"] = path
	}
	if serviceName, ok := n.Extra["serviceName"]; ok {
		t["service_name"] = serviceName
	}
	return t
}

// parseMbps extracts an integer from a bandwidth string like "50 Mbps" or "50".
func parseMbps(s string) int {
	s = strings.TrimSpace(s)
	s = strings.TrimSuffix(strings.ToLower(s), "mbps")
	s = strings.TrimSpace(s)
	var v int
	fmt.Sscanf(s, "%d", &v)
	return v
}
