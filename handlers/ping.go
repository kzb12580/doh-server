package handlers

import (
	"fmt"
	"net"
	"net/http"
	"sync"
	"time"

	"sub-store/models"

	"github.com/gin-gonic/gin"
)

// PingHandler handles node latency testing.
type PingHandler struct {
	store *models.Store
}

// NewPingHandler creates a handler wired to the given store.
func NewPingHandler(store *models.Store) *PingHandler {
	return &PingHandler{store: store}
}

type pingRequest struct {
	NodeID  string `json:"node_id"`
	Server  string `json:"server"`
	Port    int    `json:"port"`
	Timeout int    `json:"timeout"` // seconds, default 5
}

type pingResult struct {
	NodeID    string `json:"node_id,omitempty"`
	Name      string `json:"name,omitempty"`
	Server    string `json:"server"`
	Port      int    `json:"port"`
	LatencyMs int64  `json:"latency_ms"`
	Status    string `json:"status"` // ok, timeout, error
	Error     string `json:"error,omitempty"`
}

// Ping tests TCP connectivity to a single node. POST /api/nodes/ping
func (h *PingHandler) Ping(c *gin.Context) {
	var req pingRequest
	if err := c.ShouldBindJSON(&req); err != nil {
		c.JSON(http.StatusOK, gin.H{"code": 1, "message": "参数错误: " + err.Error()})
		return
	}

	timeout := req.Timeout
	if timeout <= 0 {
		timeout = 5
	}

	// If node_id provided, look up from store
	if req.NodeID != "" {
		nodes, err := h.store.ListAllNodes()
		if err != nil {
			c.JSON(http.StatusOK, gin.H{"code": 1, "message": err.Error()})
			return
		}
		for _, n := range nodes {
			if n.ID == req.NodeID {
				req.Server = n.Server
				req.Port = n.Port
				break
			}
		}
		if req.Server == "" {
			c.JSON(http.StatusOK, gin.H{"code": 1, "message": "节点不存在"})
			return
		}
	}

	if req.Server == "" || req.Port == 0 {
		c.JSON(http.StatusOK, gin.H{"code": 1, "message": "需要 server+port 或 node_id"})
		return
	}

	result := doPing(req.Server, req.Port, timeout)
	c.JSON(http.StatusOK, gin.H{"code": 0, "data": result})
}

// PingBatch tests latency for all nodes in a subscription. POST /api/nodes/ping/batch
func (h *PingHandler) PingBatch(c *gin.Context) {
	var req struct {
		SubID   string `json:"sub_id"`
		Timeout int    `json:"timeout"`
	}
	if err := c.ShouldBindJSON(&req); err != nil {
		c.JSON(http.StatusOK, gin.H{"code": 1, "message": "参数错误: " + err.Error()})
		return
	}

	timeout := req.Timeout
	if timeout <= 0 {
		timeout = 5
	}

	var nodes []models.Node
	var err error
	if req.SubID != "" {
		nodes, err = h.store.ListNodesForSub(req.SubID)
	} else {
		nodes, err = h.store.ListAllNodes()
	}
	if err != nil {
		c.JSON(http.StatusOK, gin.H{"code": 1, "message": err.Error()})
		return
	}

	results := make([]pingResult, len(nodes))
	sem := make(chan struct{}, 20) // limit concurrent
	var wg sync.WaitGroup

	for i, n := range nodes {
		wg.Add(1)
		go func(idx int, node models.Node) {
			defer wg.Done()
			sem <- struct{}{}
			defer func() { <-sem }()
			r := doPing(node.Server, node.Port, timeout)
			r.NodeID = node.ID
			r.Name = node.Name
			results[idx] = r
		}(i, n)
	}
	wg.Wait()

	c.JSON(http.StatusOK, gin.H{"code": 0, "data": results})
}

func doPing(server string, port, timeoutSec int) pingResult {
	addr := net.JoinHostPort(server, fmt.Sprintf("%d", port))
	start := time.Now()
	conn, err := net.DialTimeout("tcp", addr, time.Duration(timeoutSec)*time.Second)
	elapsed := time.Since(start).Milliseconds()

	if err != nil {
		return pingResult{
			Server:    server,
			Port:      port,
			LatencyMs: -1,
			Status:    "timeout",
			Error:     err.Error(),
		}
	}
	conn.Close()
	return pingResult{
		Server:    server,
		Port:      port,
		LatencyMs: elapsed,
		Status:    "ok",
	}
}
