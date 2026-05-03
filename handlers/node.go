package handlers

import (
	"net/http"

	"sub-store/models"

	"github.com/gin-gonic/gin"
)

// NodeHandler serves node listing and statistics.
type NodeHandler struct {
	store *models.Store
}

// NewNodeHandler creates a handler wired to the given store.
func NewNodeHandler(store *models.Store) *NodeHandler {
	return &NodeHandler{store: store}
}

// List returns nodes, optionally filtered by sub_id. GET /api/nodes?sub_id=
func (h *NodeHandler) List(c *gin.Context) {
	subID := c.Query("sub_id")

	var (
		nodes []models.Node
		err   error
	)

	if subID != "" {
		nodes, err = h.store.ListNodesForSub(subID)
	} else {
		nodes, err = h.store.ListAllNodes()
	}

	if err != nil {
		c.JSON(http.StatusOK, gin.H{"code": 1, "message": err.Error()})
		return
	}
	c.JSON(http.StatusOK, gin.H{"code": 0, "data": nodes})
}

// Stats returns aggregate node counts. GET /api/nodes/stats
func (h *NodeHandler) Stats(c *gin.Context) {
	nodes, err := h.store.ListAllNodes()
	if err != nil {
		c.JSON(http.StatusOK, gin.H{"code": 1, "message": err.Error()})
		return
	}

	byType := make(map[string]int)
	for _, n := range nodes {
		byType[n.Type]++
	}

	c.JSON(http.StatusOK, gin.H{"code": 0, "data": gin.H{
		"total":   len(nodes),
		"by_type": byType,
	}})
}
