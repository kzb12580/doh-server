package main

import (
	"embed"
	"flag"
	"fmt"
	"io/fs"
	"log"
	"net/http"
	"os"
	"os/signal"
	"syscall"

	"sub-store/config"
	"sub-store/doh"
	"sub-store/handlers"
	"sub-store/models"

	"github.com/gin-gonic/gin"
)

//go:embed frontend/dist/*
var frontendFS embed.FS

func main() {
	port := flag.Int("port", 8888, "监听端口")
	configPath := flag.String("config", "data/config.json", "配置文件路径")
	flag.Parse()

	// 加载配置
	cfg, err := config.Load(*configPath)
	if err != nil {
		log.Printf("配置加载失败，使用默认配置: %v", err)
		cfg = config.Default()
	}

	// 初始化存储
	store, err := models.NewStore(cfg.DataDir)
	if err != nil {
		log.Fatalf("存储初始化失败: %v", err)
	}

	// 初始化 DOH 解析器
	dohResolver := doh.NewResolver(cfg.DOHServers, cfg.DOHEngine)

	// 初始化路由
	if cfg.LogLevel != "debug" {
		gin.SetMode(gin.ReleaseMode)
	}
	r := gin.Default()

	// API 路由
	api := r.Group("/api")
	{
		// 订阅管理
		subHandler := handlers.NewSubscriptionHandler(store, dohResolver)
		api.GET("/subscriptions", subHandler.List)
		api.POST("/subscriptions", subHandler.Create)
		api.PUT("/subscriptions/:id", subHandler.Update)
		api.DELETE("/subscriptions/:id", subHandler.Delete)
		api.POST("/subscriptions/:id/refresh", subHandler.Refresh)

		// 节点
		nodeHandler := handlers.NewNodeHandler(store)
		api.GET("/nodes", nodeHandler.List)
		api.GET("/nodes/stats", nodeHandler.Stats)

		// 订阅转换输出
		convertHandler := handlers.NewConvertHandler(store, dohResolver)
		api.GET("/sub/:id/:format", convertHandler.Convert)
		api.GET("/sub/all/:format", convertHandler.ConvertAll)

		// DOH
		dohHandler := handlers.NewDOHHandler(dohResolver)
		api.POST("/doh/resolve", dohHandler.Resolve)
		api.GET("/doh/test", dohHandler.Test)

		// 系统
		api.GET("/system/info", func(c *gin.Context) {
			c.JSON(200, gin.H{
				"name":    "Sub-Store",
				"version": "1.0.0",
			})
		})
	}

	// 前端静态文件
	distFS, err := fs.Sub(frontendFS, "frontend/dist")
	if err != nil {
		log.Printf("前端资源未打包，跳过: %v", err)
	} else {
		fileServer := http.FileServer(http.FS(distFS))
		r.NoRoute(func(c *gin.Context) {
			// API 请求跳过
			if len(c.Request.URL.Path) >= 4 && c.Request.URL.Path[:4] == "/api" {
				c.JSON(404, gin.H{"error": "not found"})
				return
			}
			// 尝试静态文件
			f, err := distFS.Open(c.Request.URL.Path[1:])
			if err == nil {
				f.Close()
				fileServer.ServeHTTP(c.Writer, c.Request)
				return
			}
			// SPA fallback
			c.Request.URL.Path = "/"
			fileServer.ServeHTTP(c.Writer, c.Request)
		})
	}

	addr := fmt.Sprintf(":%d", *port)
	fmt.Printf("🚀 Sub-Store v1.0.0 已启动\n")
	fmt.Printf("📡 API: http://localhost%s/api\n", addr)
	fmt.Printf("🌐 Web: http://localhost%s\n", addr)

	go func() {
		if err := r.Run(addr); err != nil {
			log.Fatalf("服务启动失败: %v", err)
		}
	}()

	quit := make(chan os.Signal, 1)
	signal.Notify(quit, syscall.SIGINT, syscall.SIGTERM)
	<-quit
	fmt.Println("\n正在关闭...")
}
