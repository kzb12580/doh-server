#!/bin/bash
# Sub-Store 一键安装脚本
# 用法: curl -sSL https://raw.githubusercontent.com/kzb12580/sub-store/main/install.sh | bash -s -- --domain sub.example.com
# 或:   ./install.sh --domain sub.example.com [--port 8888] [--skip-nginx] [--skip-ssl]

set -e

# ===== 颜色 =====
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'
info()  { echo -e "${BLUE}[INFO]${NC} $1"; }
ok()    { echo -e "${GREEN}[OK]${NC} $1"; }
warn()  { echo -e "${YELLOW}[WARN]${NC} $1"; }
err()   { echo -e "${RED}[ERROR]${NC} $1"; exit 1; }

# ===== 参数 =====
DOMAIN=""
PORT=8888
SKIP_NGINX=false
SKIP_SSL=false
INSTALL_DIR="/opt/sub-store"
DATA_DIR="/opt/sub-store/data"
GITHUB_REPO="kzb12580/sub-store"

while [[ $# -gt 0 ]]; do
  case $1 in
    --domain)   DOMAIN="$2"; shift 2 ;;
    --port)     PORT="$2"; shift 2 ;;
    --skip-nginx) SKIP_NGINX=true; shift ;;
    --skip-ssl)   SKIP_SSL=true; shift ;;
    --dir)      INSTALL_DIR="$2"; DATA_DIR="$2/data"; shift 2 ;;
    -h|--help)
      echo "Sub-Store 安装脚本"
      echo ""
      echo "用法: $0 [选项]"
      echo ""
      echo "选项:"
      echo "  --domain DOMAIN    域名（如 sub.940307.xyz）"
      echo "  --port PORT        服务端口（默认 8888）"
      echo "  --dir DIR          安装目录（默认 /opt/sub-store）"
      echo "  --skip-nginx       跳过 Nginx 配置"
      echo "  --skip-ssl         跳过 SSL 证书申请"
      echo "  -h, --help         显示帮助"
      exit 0
      ;;
    *) warn "未知参数: $1"; shift ;;
  esac
done

# ===== 系统检测 =====
info "检测系统环境..."
OS="$(uname -s)"
ARCH="$(uname -m)"
case "$ARCH" in
  x86_64|amd64) ARCH="amd64" ;;
  aarch64|arm64) ARCH="arm64" ;;
  *) err "不支持的架构: $ARCH" ;;
esac

if [ "$OS" != "Linux" ]; then
  err "仅支持 Linux 系统"
fi

info "系统: $OS $ARCH"

# ===== 依赖检查 =====
check_cmd() {
  command -v "$1" &>/dev/null
}

# Go (编译需要)
NEED_BUILD=false
if check_cmd go; then
  GO_VER=$(go version | grep -oP 'go\K[0-9.]+')
  info "已安装 Go $GO_VER"
else
  info "未检测到 Go，将下载预编译二进制"
  NEED_BUILD=false  # 用预编译的
fi

# Git
if ! check_cmd git; then
  info "安装 git..."
  if check_cmd apt-get; then apt-get update -qq && apt-get install -y -qq git >/dev/null 2>&1
  elif check_cmd yum; then yum install -y -q git >/dev/null 2>&1
  elif check_cmd dnf; then dnf install -y -q git >/dev/null 2>&1
  fi
fi

# ===== 获取代码 =====
info "获取 Sub-Store..."

# Check if we're running from the repo
if [ -f "./main.go" ] && [ -f "./go.mod" ]; then
  info "从当前目录构建..."
  SRC_DIR="."
  NEED_BUILD=true
elif [ -d "$INSTALL_DIR/src" ]; then
  info "更新现有源码..."
  cd "$INSTALL_DIR/src"
  git pull --quiet 2>/dev/null || true
  SRC_DIR="$INSTALL_DIR/src"
  NEED_BUILD=true
else
  info "克隆仓库..."
  mkdir -p "$INSTALL_DIR"
  git clone --quiet "https://github.com/${GITHUB_REPO}.git" "$INSTALL_DIR/src" 2>/dev/null || {
    # 如果 clone 失败，尝试从 release 下载预编译
    warn "Git clone 失败，尝试下载预编译版本..."
    NEED_BUILD=false
  }
  SRC_DIR="$INSTALL_DIR/src"
  NEED_BUILD=true
fi

# ===== 编译 =====
mkdir -p "$INSTALL_DIR" "$DATA_DIR"

if [ "$NEED_BUILD" = true ] && check_cmd go; then
  info "编译 Sub-Store..."
  cd "$SRC_DIR"
  CGO_ENABLED=0 go build -ldflags="-s -w" -o "$INSTALL_DIR/sub-store" . 2>&1
  ok "编译完成"
elif [ ! -f "$INSTALL_DIR/sub-store" ]; then
  # 尝试从 GitHub Release 下载
  info "下载预编译版本..."
  RELEASE_URL="https://github.com/${GITHUB_REPO}/releases/latest/download/sub-store-linux-${ARCH}"
  if curl -sSL -o "$INSTALL_DIR/sub-store" "$RELEASE_URL" 2>/dev/null; then
    chmod +x "$INSTALL_DIR/sub-store"
    ok "下载完成"
  else
    err "无法获取 Sub-Store 二进制，请确保已安装 Go 并从源码编译"
  fi
fi

chmod +x "$INSTALL_DIR/sub-store"

# ===== 配置文件 =====
if [ ! -f "$DATA_DIR/config.json" ]; then
  info "生成配置文件..."
  cat > "$DATA_DIR/config.json" << 'EOF'
{
  "data_dir": "data",
  "log_level": "info",
  "doh_servers": ["https://cloudflare-dns.com/dns-query", "https://dns.google/dns-query"],
  "doh_engine": "cloudflare"
}
EOF
  ok "配置已生成"
fi

# ===== Systemd 服务 =====
info "创建 systemd 服务..."
cat > /etc/systemd/system/sub-store.service << EOF
[Unit]
Description=Sub-Store Subscription Manager
After=network.target

[Service]
Type=simple
User=root
WorkingDirectory=${INSTALL_DIR}
ExecStart=${INSTALL_DIR}/sub-store -port ${PORT} -config ${DATA_DIR}/config.json
Restart=on-failure
RestartSec=5
LimitNOFILE=65536

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable sub-store --quiet
systemctl restart sub-store
ok "服务已启动 (端口: $PORT)"

# ===== Nginx =====
if [ "$SKIP_NGINX" = false ] && [ -n "$DOMAIN" ]; then
  # 安装 Nginx（如果没有）
  if ! check_cmd nginx; then
    info "安装 Nginx..."
    if check_cmd apt-get; then apt-get update -qq && apt-get install -y -qq nginx >/dev/null 2>&1
    elif check_cmd yum; then yum install -y -q nginx >/dev/null 2>&1
    elif check_cmd dnf; then dnf install -y -q nginx >/dev/null 2>&1
    fi
  fi

  info "配置 Nginx 反向代理..."

  # HTTP 配置（先确保能访问）
  cat > /etc/nginx/sites-available/sub-store << EOF
server {
    listen 80;
    server_name ${DOMAIN};

    location / {
        proxy_pass http://127.0.0.1:${PORT};
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_read_timeout 300s;
        proxy_connect_timeout 10s;
    }
}
EOF

  # 启用站点
  mkdir -p /etc/nginx/sites-available /etc/nginx/sites-enabled
  ln -sf /etc/nginx/sites-available/sub-store /etc/nginx/sites-enabled/sub-store

  # 删除默认站点
  rm -f /etc/nginx/sites-enabled/default

  nginx -t 2>&1 && systemctl reload nginx
  ok "Nginx 配置完成"

  # ===== SSL 证书 =====
  if [ "$SKIP_SSL" = false ]; then
    info "申请 SSL 证书..."
    if ! check_cmd certbot; then
      if check_cmd apt-get; then
        apt-get update -qq && apt-get install -y -qq certbot python3-certbot-nginx >/dev/null 2>&1
      elif check_cmd yum || check_cmd dnf; then
        yum install -y -q certbot python3-certbot-nginx 2>/dev/null || dnf install -y -q certbot python3-certbot-nginx 2>/dev/null
      fi
    fi

    if check_cmd certbot; then
      certbot --nginx -d "$DOMAIN" --non-interactive --agree-tos --email "admin@${DOMAIN}" --redirect 2>&1 || {
        warn "SSL 证书申请失败（可能需要先配置 DNS A 记录）"
        warn "请确保 ${DOMAIN} 已解析到本机 IP，然后运行: certbot --nginx -d ${DOMAIN}"
      }

      # 自动续期
      systemctl enable certbot.timer 2>/dev/null || true
      systemctl start certbot.timer 2>/dev/null || true
      ok "SSL 证书配置完成"
    else
      warn "certbot 未安装，请手动申请 SSL 证书"
    fi
  fi
fi

# ===== 完成 =====
echo ""
echo -e "${GREEN}══════════════════════════════════════════════════${NC}"
echo -e "${GREEN}  ✅ Sub-Store 安装完成！${NC}"
echo -e "${GREEN}══════════════════════════════════════════════════${NC}"
echo ""
echo -e "  📡 本地访问: ${BLUE}http://localhost:${PORT}${NC}"
if [ -n "$DOMAIN" ]; then
  if [ "$SKIP_SSL" = false ]; then
    echo -e "  🌐 域名访问: ${BLUE}https://${DOMAIN}${NC}"
  else
    echo -e "  🌐 域名访问: ${BLUE}http://${DOMAIN}${NC}"
  fi
fi
echo ""
echo -e "  📋 管理命令:"
echo -e "     启动: ${YELLOW}systemctl start sub-store${NC}"
echo -e "     停止: ${YELLOW}systemctl stop sub-store${NC}"
echo -e "     重启: ${YELLOW}systemctl restart sub-store${NC}"
echo -e "     日志: ${YELLOW}journalctl -u sub-store -f${NC}"
echo -e "     状态: ${YELLOW}systemctl status sub-store${NC}"
echo ""
echo -e "  📁 安装目录: ${YELLOW}${INSTALL_DIR}${NC}"
echo -e "  📁 数据目录: ${YELLOW}${DATA_DIR}${NC}"
echo ""
