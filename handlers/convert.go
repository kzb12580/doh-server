package handlers

import (
	"fmt"
	"net/http"

	"sub-store/converter"
	"sub-store/doh"
	"sub-store/models"

	"github.com/gin-gonic/gin"
)

// ConvertHandler converts subscription nodes into Clash or sing-box configs.
type ConvertHandler struct {
	store    *models.Store
	resolver *doh.Resolver
}

// NewConvertHandler creates a handler wired to the given store and DoH resolver.
func NewConvertHandler(store *models.Store, resolver *doh.Resolver) *ConvertHandler {
	return &ConvertHandler{store: store, resolver: resolver}
}

// Convert produces a config for a single subscription. GET /api/sub/:id/:format
func (h *ConvertHandler) Convert(c *gin.Context) {
	id := c.Param("id")
	format := c.Param("format")

	nodes, err := h.store.ListNodesForSub(id)
	if err != nil {
		c.JSON(http.StatusOK, gin.H{"code": 1, "message": err.Error()})
		return
	}
	if len(nodes) == 0 {
		c.JSON(http.StatusOK, gin.H{"code": 1, "message": "无节点数据"})
		return
	}

	data, err := h.generate(nodes, format)
	if err != nil {
		c.JSON(http.StatusOK, gin.H{"code": 1, "message": err.Error()})
		return
	}

	c.Data(http.StatusOK, h.contentType(format), data)
}

// ConvertAll produces a config for all subscriptions. GET /api/sub/all/:format
func (h *ConvertHandler) ConvertAll(c *gin.Context) {
	format := c.Param("format")

	nodes, err := h.store.ListAllNodes()
	if err != nil {
		c.JSON(http.StatusOK, gin.H{"code": 1, "message": err.Error()})
		return
	}
	if len(nodes) == 0 {
		c.JSON(http.StatusOK, gin.H{"code": 1, "message": "无节点数据"})
		return
	}

	data, err := h.generate(nodes, format)
	if err != nil {
		c.JSON(http.StatusOK, gin.H{"code": 1, "message": err.Error()})
		return
	}

	c.Data(http.StatusOK, h.contentType(format), data)
}

// generate dispatches to the appropriate converter function.
func (h *ConvertHandler) generate(nodes []models.Node, format string) ([]byte, error) {
	switch format {
	case "clash":
		return converter.GenerateClash(nodes, h.resolver)
	case "singbox":
		return converter.GenerateSingBox(nodes, h.resolver)
	default:
		return nil, fmt.Errorf("不支持的格式: %s (可选: clash, singbox)", format)
	}
}

// contentType returns the MIME type for the given format.
func (h *ConvertHandler) contentType(format string) string {
	switch format {
	case "clash":
		return "text/yaml; charset=utf-8"
	case "singbox":
		return "application/json; charset=utf-8"
	default:
		return "text/plain; charset=utf-8"
	}
}
