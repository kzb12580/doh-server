package handlers

import (
	"encoding/base64"
	"net/http"
	"strings"
	"time"

	"sub-store/models"
	"sub-store/parser"

	"github.com/gin-gonic/gin"
	"github.com/google/uuid"
)

// ImportHandler handles batch subscription import/export.
type ImportHandler struct {
	store *models.Store
}

// NewImportHandler creates a handler wired to the given store.
func NewImportHandler(store *models.Store) *ImportHandler {
	return &ImportHandler{store: store}
}

// Import adds multiple subscriptions at once. POST /api/subscriptions/import
func (h *ImportHandler) Import(c *gin.Context) {
	var req struct {
		URLs []struct {
			Name string `json:"name"`
			URL  string `json:"url"`
		} `json:"urls" binding:"required"`
		AutoRefresh bool `json:"auto_refresh"`
		Interval    int  `json:"interval"`
	}
	if err := c.ShouldBindJSON(&req); err != nil {
		c.JSON(http.StatusOK, gin.H{"code": 1, "message": "参数错误: " + err.Error()})
		return
	}

	type detail struct {
		Name     string `json:"name"`
		Status   string `json:"status"`
		NodeCount int   `json:"node_count,omitempty"`
		Error    string `json:"error,omitempty"`
	}

	var details []detail
	created := 0

	for _, item := range req.URLs {
		name := item.Name
		if name == "" {
			name = "Imported " + time.Now().Format("0102-150405")
		}

		sub := models.Subscription{
			ID:          uuid.New().String(),
			Name:        name,
			URL:         item.URL,
			AutoRefresh: req.AutoRefresh,
			Interval:    req.Interval,
			CreatedAt:   time.Now(),
			UpdatedAt:   time.Now(),
		}

		// Try to parse immediately
		nodes, err := parser.FetchAndParse(item.URL)
		if err == nil && len(nodes) > 0 {
			for i := range nodes {
				nodes[i].SubID = sub.ID
			}
			_ = h.store.SaveNodesForSub(sub.ID, nodes)
			sub.NodeCount = len(nodes)
		}

		if err := h.store.SaveSubscription(&sub); err != nil {
			details = append(details, detail{Name: name, Status: "error", Error: err.Error()})
			continue
		}

		created++
		details = append(details, detail{
			Name:      name,
			Status:    "ok",
			NodeCount: sub.NodeCount,
		})
	}

	c.JSON(http.StatusOK, gin.H{"code": 0, "data": gin.H{
		"created": created,
		"total":   len(req.URLs),
		"details": details,
	}})
}

// Export returns all subscriptions with their nodes. GET /api/subscriptions/export
func (h *ImportHandler) Export(c *gin.Context) {
	subs, err := h.store.ListSubscriptions()
	if err != nil {
		c.JSON(http.StatusOK, gin.H{"code": 1, "message": err.Error()})
		return
	}

	type exportSub struct {
		models.Subscription
		Nodes []models.Node `json:"nodes"`
	}

	var result []exportSub
	for _, sub := range subs {
		nodes, _ := h.store.ListNodesForSub(sub.ID)
		result = append(result, exportSub{Subscription: sub, Nodes: nodes})
	}

	c.JSON(http.StatusOK, gin.H{"code": 0, "data": result})
}

// ImportText parses a text blob of subscription URIs. POST /api/subscriptions/import-text
func (h *ImportHandler) ImportText(c *gin.Context) {
	var req struct {
		Text string `json:"text" binding:"required"`
		Name string `json:"name"`
	}
	if err := c.ShouldBindJSON(&req); err != nil {
		c.JSON(http.StatusOK, gin.H{"code": 1, "message": "参数错误: " + err.Error()})
		return
	}

	name := req.Name
	if name == "" {
		name = "Imported " + time.Now().Format("0102-150405")
	}

	// Try base64 decode
	text := strings.TrimSpace(req.Text)
	decoded, err := base64.StdEncoding.DecodeString(text)
	if err != nil {
		decoded, err = base64.URLEncoding.DecodeString(text)
		if err != nil {
			decoded = []byte(text)
		}
	}

	lines := strings.Split(strings.TrimSpace(string(decoded)), "\n")
	var nodes []models.Node
	for _, line := range lines {
		line = strings.TrimSpace(line)
		if line == "" {
			continue
		}
		// Check if it's a subscription URL (http/https)
		if strings.HasPrefix(line, "http://") || strings.HasPrefix(line, "https://") {
			// Create a subscription for this URL
			sub := models.Subscription{
				ID:        uuid.New().String(),
				Name:      name,
				URL:       line,
				CreatedAt: time.Now(),
				UpdatedAt: time.Now(),
			}
			parsedNodes, err := parser.FetchAndParse(line)
			if err == nil {
				for i := range parsedNodes {
					parsedNodes[i].SubID = sub.ID
				}
				_ = h.store.SaveNodesForSub(sub.ID, parsedNodes)
				sub.NodeCount = len(parsedNodes)
			}
			_ = h.store.SaveSubscription(&sub)
			c.JSON(http.StatusOK, gin.H{"code": 0, "data": gin.H{
				"subscription": sub,
				"node_count":   sub.NodeCount,
			}})
			return
		}
	}

	// Not a URL, try parsing as proxy URIs directly
	sub := models.Subscription{
		ID:        uuid.New().String(),
		Name:      name,
		URL:       "local://import-text",
		CreatedAt: time.Now(),
		UpdatedAt: time.Now(),
	}

	for _, line := range lines {
		line = strings.TrimSpace(line)
		if line == "" {
			continue
		}
		node, err := parser.ParseSingleURI(line)
		if err != nil {
			continue
		}
		node.SubID = sub.ID
		nodes = append(nodes, *node)
	}

	if len(nodes) == 0 {
		c.JSON(http.StatusOK, gin.H{"code": 1, "message": "无法解析任何节点"})
		return
	}

	_ = h.store.SaveNodesForSub(sub.ID, nodes)
	sub.NodeCount = len(nodes)
	_ = h.store.SaveSubscription(&sub)

	c.JSON(http.StatusOK, gin.H{"code": 0, "data": gin.H{
		"subscription": sub,
		"node_count":   len(nodes),
	}})
}
