package handlers

import (
	"net/http"

	"sub-store/doh"

	"github.com/gin-gonic/gin"
)

// DOHHandler exposes DNS-over-HTTPS resolution endpoints.
type DOHHandler struct {
	resolver *doh.Resolver
}

// NewDOHHandler creates a handler wired to the given DoH resolver.
func NewDOHHandler(resolver *doh.Resolver) *DOHHandler {
	return &DOHHandler{resolver: resolver}
}

// Resolve resolves a domain via DoH. POST /api/doh/resolve
func (h *DOHHandler) Resolve(c *gin.Context) {
	var req struct {
		Domain string `json:"domain" binding:"required"`
	}
	if err := c.ShouldBindJSON(&req); err != nil {
		c.JSON(http.StatusOK, gin.H{"code": 1, "message": "参数错误: " + err.Error()})
		return
	}

	ips, err := h.resolver.Resolve(req.Domain)
	if err != nil {
		c.JSON(http.StatusOK, gin.H{"code": 1, "message": "解析失败: " + err.Error()})
		return
	}

	c.JSON(http.StatusOK, gin.H{"code": 0, "data": gin.H{
		"domain": req.Domain,
		"ips":    ips,
	}})
}

// Test checks DoH connectivity. GET /api/doh/test
func (h *DOHHandler) Test(c *gin.Context) {
	err := h.resolver.Test()
	if err != nil {
		c.JSON(http.StatusOK, gin.H{"code": 1, "message": "DoH 测试失败: " + err.Error()})
		return
	}

	c.JSON(http.StatusOK, gin.H{"code": 0, "data": gin.H{
		"status":  "ok",
		"message": "DoH 解析正常",
	}})
}
