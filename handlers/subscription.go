package handlers

import (
	"net/http"
	"time"

	"sub-store/doh"
	"sub-store/models"
	"sub-store/parser"
	"sub-store/scheduler"

	"github.com/gin-gonic/gin"
	"github.com/google/uuid"
)

// SubscriptionHandler manages subscription CRUD and refresh.
type SubscriptionHandler struct {
	store    *models.Store
	resolver *doh.Resolver
	sched    *scheduler.Scheduler
}

// NewSubscriptionHandler creates a handler wired to the given store, DoH resolver, and scheduler.
func NewSubscriptionHandler(store *models.Store, resolver *doh.Resolver, sched *scheduler.Scheduler) *SubscriptionHandler {
	return &SubscriptionHandler{store: store, resolver: resolver, sched: sched}
}

// List returns all subscriptions. GET /api/subscriptions
func (h *SubscriptionHandler) List(c *gin.Context) {
	subs, err := h.store.ListSubscriptions()
	if err != nil {
		c.JSON(http.StatusOK, gin.H{"code": 1, "message": err.Error()})
		return
	}
	c.JSON(http.StatusOK, gin.H{"code": 0, "data": subs})
}

// Create adds a new subscription. POST /api/subscriptions
func (h *SubscriptionHandler) Create(c *gin.Context) {
	var req struct {
		Name        string `json:"name" binding:"required"`
		URL         string `json:"url" binding:"required"`
		AutoRefresh bool   `json:"auto_refresh"`
		Interval    int    `json:"interval"`
	}
	if err := c.ShouldBindJSON(&req); err != nil {
		c.JSON(http.StatusOK, gin.H{"code": 1, "message": "参数错误: " + err.Error()})
		return
	}

	sub := models.Subscription{
		ID:          uuid.New().String(),
		Name:        req.Name,
		URL:         req.URL,
		AutoRefresh: req.AutoRefresh,
		Interval:    req.Interval,
		CreatedAt:   time.Now(),
		UpdatedAt:   time.Now(),
	}

	if err := h.store.SaveSubscription(&sub); err != nil {
		c.JSON(http.StatusOK, gin.H{"code": 1, "message": err.Error()})
		return
	}
	c.JSON(http.StatusOK, gin.H{"code": 0, "data": sub})
}

// Update modifies an existing subscription. PUT /api/subscriptions/:id
func (h *SubscriptionHandler) Update(c *gin.Context) {
	id := c.Param("id")
	existing, err := h.store.GetSubscription(id)
	if err != nil {
		c.JSON(http.StatusOK, gin.H{"code": 1, "message": "订阅不存在"})
		return
	}

	var req struct {
		Name        *string `json:"name"`
		URL         *string `json:"url"`
		AutoRefresh *bool   `json:"auto_refresh"`
		Interval    *int    `json:"interval"`
	}
	if err := c.ShouldBindJSON(&req); err != nil {
		c.JSON(http.StatusOK, gin.H{"code": 1, "message": "参数错误: " + err.Error()})
		return
	}

	if req.Name != nil {
		existing.Name = *req.Name
	}
	if req.URL != nil {
		existing.URL = *req.URL
	}
	if req.AutoRefresh != nil {
		existing.AutoRefresh = *req.AutoRefresh
	}
	if req.Interval != nil {
		existing.Interval = *req.Interval
	}
	existing.UpdatedAt = time.Now()

	if err := h.store.SaveSubscription(existing); err != nil {
		c.JSON(http.StatusOK, gin.H{"code": 1, "message": err.Error()})
		return
	}
	c.JSON(http.StatusOK, gin.H{"code": 0, "data": existing})
}

// Delete removes a subscription and its associated nodes. DELETE /api/subscriptions/:id
func (h *SubscriptionHandler) Delete(c *gin.Context) {
	id := c.Param("id")
	if err := h.store.DeleteSubscription(id); err != nil {
		c.JSON(http.StatusOK, gin.H{"code": 1, "message": err.Error()})
		return
	}
	c.JSON(http.StatusOK, gin.H{"code": 0, "data": nil})
}

// Refresh re-fetches and parses the subscription URL. POST /api/subscriptions/:id/refresh
func (h *SubscriptionHandler) Refresh(c *gin.Context) {
	id := c.Param("id")

	if h.sched != nil {
		count, err := h.sched.RefreshSub(id)
		if err != nil {
			c.JSON(http.StatusOK, gin.H{"code": 1, "message": "刷新失败: " + err.Error()})
			return
		}
		sub, _ := h.store.GetSubscription(id)
		c.JSON(http.StatusOK, gin.H{"code": 0, "data": gin.H{
			"subscription": sub,
			"node_count":   count,
		}})
		return
	}

	// Fallback without scheduler
	sub, err := h.store.GetSubscription(id)
	if err != nil {
		c.JSON(http.StatusOK, gin.H{"code": 1, "message": "订阅不存在"})
		return
	}

	nodes, err := parser.FetchAndParse(sub.URL)
	if err != nil {
		c.JSON(http.StatusOK, gin.H{"code": 1, "message": "解析失败: " + err.Error()})
		return
	}

	for i := range nodes {
		if nodes[i].ID == "" {
			nodes[i].ID = uuid.New().String()
		}
		nodes[i].SubID = id
	}

	if err := h.store.SaveNodesForSub(id, nodes); err != nil {
		c.JSON(http.StatusOK, gin.H{"code": 1, "message": err.Error()})
		return
	}

	sub.NodeCount = len(nodes)
	sub.UpdatedAt = time.Now()
	_ = h.store.SaveSubscription(sub)

	c.JSON(http.StatusOK, gin.H{"code": 0, "data": gin.H{
		"subscription": sub,
		"node_count":   len(nodes),
	}})
}

// RefreshAll re-fetches all subscriptions. POST /api/subscriptions/refresh-all
func (h *SubscriptionHandler) RefreshAll(c *gin.Context) {
	if h.sched != nil {
		err := h.sched.RefreshAll()
		if err != nil {
			c.JSON(http.StatusOK, gin.H{"code": 1, "message": "部分刷新失败: " + err.Error()})
			return
		}
		c.JSON(http.StatusOK, gin.H{"code": 0, "data": gin.H{"message": "全部刷新完成"}})
		return
	}
	c.JSON(http.StatusOK, gin.H{"code": 1, "message": "调度器未初始化"})
}
