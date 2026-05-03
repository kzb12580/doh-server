package models

import (
	"encoding/json"
	"os"
	"path/filepath"
	"time"
)

// Subscription 订阅源
type Subscription struct {
	ID          string    `json:"id"`
	Name        string    `json:"name"`
	URL         string    `json:"url"`
	AutoRefresh bool      `json:"auto_refresh"`
	Interval    int       `json:"interval"` // 分钟
	NodeCount   int       `json:"node_count"`
	UpdatedAt   time.Time `json:"updated_at"`
	CreatedAt   time.Time `json:"created_at"`
}

// Node 代理节点
type Node struct {
	ID         string            `json:"id"`
	SubID      string            `json:"sub_id"`      // 所属订阅
	Name       string            `json:"name"`
	Type       string            `json:"type"`         // vmess, vless, trojan, ss, hysteria2, tuic
	Server     string            `json:"server"`
	Port       int               `json:"port"`
	Password   string            `json:"password,omitempty"`
	UUID       string            `json:"uuid,omitempty"`
	Transport  string            `json:"transport,omitempty"` // tcp, ws, grpc, h2
	TLS        bool              `json:"tls"`
	SNI        string            `json:"sni,omitempty"`
	Alpn       []string          `json:"alpn,omitempty"`
	Plugin     string            `json:"plugin,omitempty"`
	PluginOpts string            `json:"plugin_opts,omitempty"`
	Extra      map[string]string `json:"extra,omitempty"` // 协议特有字段
	RawURI     string            `json:"raw_uri"`         // 原始 URI
}

// Store 数据存储
type Store struct {
	dataDir string
}

func NewStore(dataDir string) (*Store, error) {
	for _, dir := range []string{"", "subscriptions", "nodes"} {
		if err := os.MkdirAll(filepath.Join(dataDir, dir), 0755); err != nil {
			return nil, err
		}
	}
	return &Store{dataDir: dataDir}, nil
}

// === 订阅操作 ===

func (s *Store) ListSubscriptions() ([]Subscription, error) {
	return s.loadSubs()
}

func (s *Store) GetSubscription(id string) (*Subscription, error) {
	subs, err := s.loadSubs()
	if err != nil {
		return nil, err
	}
	for _, sub := range subs {
		if sub.ID == id {
			return &sub, nil
		}
	}
	return nil, os.ErrNotExist
}

func (s *Store) SaveSubscription(sub *Subscription) error {
	subs, err := s.loadSubs()
	if err != nil {
		subs = []Subscription{}
	}
	found := false
	for i, existing := range subs {
		if existing.ID == sub.ID {
			subs[i] = *sub
			found = true
			break
		}
	}
	if !found {
		subs = append(subs, *sub)
	}
	return s.saveSubs(subs)
}

func (s *Store) DeleteSubscription(id string) error {
	subs, err := s.loadSubs()
	if err != nil {
		return err
	}
	filtered := make([]Subscription, 0, len(subs))
	for _, sub := range subs {
		if sub.ID != id {
			filtered = append(filtered, sub)
		}
	}
	if err := s.saveSubs(filtered); err != nil {
		return err
	}
	// 删除关联节点
	return s.saveNodesForSub(id, nil)
}

// === 节点操作 ===

func (s *Store) ListAllNodes() ([]Node, error) {
	return s.loadAllNodes()
}

func (s *Store) ListNodesForSub(subID string) ([]Node, error) {
	return s.loadNodesForSub(subID)
}

func (s *Store) SaveNodesForSub(subID string, nodes []Node) error {
	return s.saveNodesForSub(subID, nodes)
}

// === 内部方法 ===

func (s *Store) loadSubs() ([]Subscription, error) {
	path := filepath.Join(s.dataDir, "subscriptions.json")
	data, err := os.ReadFile(path)
	if err != nil {
		return []Subscription{}, nil
	}
	var subs []Subscription
	if err := json.Unmarshal(data, &subs); err != nil {
		return nil, err
	}
	return subs, nil
}

func (s *Store) saveSubs(subs []Subscription) error {
	path := filepath.Join(s.dataDir, "subscriptions.json")
	data, err := json.MarshalIndent(subs, "", "  ")
	if err != nil {
		return err
	}
	return os.WriteFile(path, data, 0644)
}

func (s *Store) loadNodesForSub(subID string) ([]Node, error) {
	path := filepath.Join(s.dataDir, "nodes", subID+".json")
	data, err := os.ReadFile(path)
	if err != nil {
		return []Node{}, nil
	}
	var nodes []Node
	if err := json.Unmarshal(data, &nodes); err != nil {
		return nil, err
	}
	return nodes, nil
}

func (s *Store) loadAllNodes() ([]Node, error) {
	subs, err := s.loadSubs()
	if err != nil {
		return nil, err
	}
	var all []Node
	for _, sub := range subs {
		nodes, err := s.loadNodesForSub(sub.ID)
		if err != nil {
			continue
		}
		all = append(all, nodes...)
	}
	return all, nil
}

func (s *Store) saveNodesForSub(subID string, nodes []Node) error {
	path := filepath.Join(s.dataDir, "nodes", subID+".json")
	data, err := json.MarshalIndent(nodes, "", "  ")
	if err != nil {
		return err
	}
	return os.WriteFile(path, data, 0644)
}
