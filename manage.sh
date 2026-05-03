#!/bin/bash
# ═══════════════════════════════════════════════════════════════
#  DOH + 安全加固 管理脚本
#  用法: bash manage.sh
# ═══════════════════════════════════════════════════════════════

R='\033[0;31m'; G='\033[0;32m'; Y='\033[1;33m'; B='\033[0;34m'; C='\033[0;36m'; M='\033[0;35m'; N='\033[0m'
p()  { echo -e "${B}[·]${N} $1"; }
ok() { echo -e "${G}[✓]${N} $1"; }
wr() { echo -e "${Y}[!]${N} $1"; }
die(){ echo -e "${R}[✗]${N} $1"; exit 1; }

DIR="/opt/doh-server"
DOH_DIR="$DIR/doh"
WEB_DIR="/var/www"
ENV_FILE="$DIR/.env"

load_env() {
  SERVER_IP=""; PORT=80; DOH_PATH="/dns-query"; SSH_PORT=307; DOMAIN=""
  [ -f "$ENV_FILE" ] && source "$ENV_FILE"
  # 检测 IP
  [ -z "$SERVER_IP" ] && SERVER_IP=$(curl -4 -s --connect-timeout 5 ifconfig.me 2>/dev/null || echo "未检测到")
}

get_ip() {
  curl -4 -s --connect-timeout 5 ifconfig.me 2>/dev/null || \
  curl -4 -s --connect-timeout 5 ip.sb 2>/dev/null || \
  curl -4 -s --connect-timeout 5 api.ipify.org 2>/dev/null || echo ""
}

# ─── 安装（IP 模式）─────────────────────────────────────────────
install_ip() {
  echo ""
  echo -e "${C}  安装 DOH（IP 直连模式）${N}"
  echo ""

  local IP=$(get_ip)
  local PORT_IN
  echo -n "  服务端口 [80]: "
  read -r PORT_IN </dev/tty 2>/dev/null || PORT_IN=""
  PORT_IN=${PORT_IN:-80}

  echo -n "  SSH 端口 [307]: "
  read -r SSH_IN </dev/tty 2>/dev/null || SSH_IN=""
  SSH_IN=${SSH_IN:-307}

  echo ""
  p "开始安装..."

  install_deps
  setup_doh
  setup_firewall "$SSH_IN" "$PORT_IN"

  mkdir -p "$DIR"
  cat > "$ENV_FILE" << EOF
SERVER_IP=$IP
PORT=$PORT_IN
DOH_PATH=/dns-query
SSH_PORT=$SSH_IN
DOMAIN=
EOF

  echo ""
  echo -e "${G}╔══════════════════════════════════════════════════════╗${N}"
  echo -e "${G}║                  ✅ 安装完成！                        ║${N}"
  echo -e "${G}╚══════════════════════════════════════════════════════╝${N}"
  echo ""
  echo -e "  🔒 DOH:  ${C}http://${IP}:${PORT_IN}/dns-query?name=google.com${N}"
  echo ""
}

# ─── 安装（域名模式）─────────────────────────────────────────────
install_domain() {
  echo ""
  echo -e "${C}  安装 DOH（域名 + HTTPS 模式）${N}"
  echo ""

  local DOMAIN_IN IP PORT_IN SSH_IN DOH_PATH_IN
  echo -n "  域名: "
  read -r DOMAIN_IN </dev/tty 2>/dev/null || DOMAIN_IN=""
  [ -z "$DOMAIN_IN" ] && die "域名不能为空"

  IP=$(get_ip)
  echo -n "  SSH 端口 [307]: "
  read -r SSH_IN </dev/tty 2>/dev/null || SSH_IN=""
  SSH_IN=${SSH_IN:-307}

  echo -n "  DOH 路径 [/dns-query]: "
  read -r DOH_PATH_IN </dev/tty 2>/dev/null || DOH_PATH_IN=""
  DOH_PATH_IN=${DOH_PATH_IN:-/dns-query}

  echo ""
  p "开始安装..."

  install_deps
  setup_doh
  setup_caddy "$DOMAIN_IN" "$DOH_PATH_IN"
  setup_decoy "$DOMAIN_IN"
  setup_firewall "$SSH_IN" "80" "443"

  mkdir -p "$DIR"
  cat > "$ENV_FILE" << EOF
SERVER_IP=$IP
PORT=80
DOH_PATH=$DOH_PATH_IN
SSH_PORT=$SSH_IN
DOMAIN=$DOMAIN_IN
EOF

  echo ""
  echo -e "${G}╔══════════════════════════════════════════════════════╗${N}"
  echo -e "${G}║                  ✅ 安装完成！                        ║${N}"
  echo -e "${G}╚══════════════════════════════════════════════════════╝${N}"
  echo ""
  echo -e "  🌐 网站:  ${C}https://${DOMAIN_IN}${N}"
  echo -e "  🔒 DOH:   ${C}https://${DOMAIN_IN}${DOH_PATH_IN}?name=google.com${N}"
  echo ""
  echo -e "  ${Y}请确保 ${DOMAIN_IN} 的 A 记录指向 ${IP}${N}"
  echo ""
}

# ─── 添加域名 ────────────────────────────────────────────────────
add_domain() {
  load_env
  if [ -n "$DOMAIN" ]; then
    wr "当前已绑定域名: $DOMAIN"
    echo -n "  更换域名？[y/N] "
    read -r CONFIRM </dev/tty 2>/dev/null || CONFIRM="n"
    [[ ! "$CONFIRM" =~ ^[Yy]$ ]] && return
  fi

  echo ""
  echo -n "  域名: "
  read -r DOMAIN_IN </dev/tty 2>/dev/null || DOMAIN_IN=""
  [ -z "$DOMAIN_IN" ] && die "域名不能为空"

  p "配置 Caddy..."
  setup_caddy "$DOMAIN_IN" "$DOH_PATH"
  setup_decoy "$DOMAIN_IN"

  # 放行 80/443
  if command -v ufw &>/dev/null; then
    ufw status | grep -q "80/tcp"  || ufw allow 80/tcp  comment "HTTP" </dev/null 2>/dev/null
    ufw status | grep -q "443/tcp" || ufw allow 443/tcp comment "HTTPS" </dev/null 2>/dev/null
    ufw reload 2>/dev/null || true
  fi

  # 更新 .env
  if [ -f "$ENV_FILE" ]; then
    sed -i "s/^DOMAIN=.*/DOMAIN=$DOMAIN_IN/" "$ENV_FILE"
  fi

  echo ""
  ok "域名已绑定: $DOMAIN_IN"
  echo -e "  🌐 ${C}https://${DOMAIN_IN}${N}"
  echo -e "  🔒 ${C}https://${DOMAIN_IN}${DOH_PATH}?name=google.com${N}"
  echo ""
}

# ─── 删除域名 ────────────────────────────────────────────────────
remove_domain() {
  load_env
  if [ -z "$DOMAIN" ]; then
    wr "当前未绑定域名"
    return
  fi

  echo ""
  echo -n "  确认解绑域名 $DOMAIN？[y/N] "
  read -r CONFIRM </dev/tty 2>/dev/null || CONFIRM="n"
  [[ ! "$CONFIRM" =~ ^[Yy]$ ]] && return

  p "清理 Caddy..."
  systemctl stop caddy 2>/dev/null || true
  echo ':80 { respond "OK" }' > /etc/caddy/Caddyfile 2>/dev/null || true
  rm -rf "${WEB_DIR}/${DOMAIN}" 2>/dev/null || true
  systemctl start caddy 2>/dev/null || true

  if [ -f "$ENV_FILE" ]; then
    sed -i "s/^DOMAIN=.*/DOMAIN=/" "$ENV_FILE"
  fi

  ok "域名已解绑"
}

# ─── 查看状态 ────────────────────────────────────────────────────
show_status() {
  load_env
  echo ""
  echo -e "${C}  ═══ 服务状态 ═══${N}"
  echo ""

  # DOH 容器
  if docker ps --format '{{.Names}}' 2>/dev/null | grep -q "doh-server"; then
    echo -e "  DOH 服务:  ${G}运行中${N}"
  else
    echo -e "  DOH 服务:  ${R}未运行${N}"
  fi
  if docker ps --format '{{.Names}}' 2>/dev/null | grep -q "doh-coredns"; then
    echo -e "  CoreDNS:   ${G}运行中${N}"
  else
    echo -e "  CoreDNS:   ${R}未运行${N}"
  fi

  # Caddy
  if systemctl is-active --quiet caddy 2>/dev/null; then
    echo -e "  Caddy:     ${G}运行中${N}"
  else
    echo -e "  Caddy:     ${Y}未运行${N}"
  fi

  # 防火墙
  if command -v ufw &>/dev/null && ufw status 2>/dev/null | grep -q "Status: active"; then
    echo -e "  防火墙:    ${G}已启用${N}"
  else
    echo -e "  防火墙:    ${Y}未启用${N}"
  fi

  echo ""
  echo -e "${C}  ═══ 访问信息 ═══${N}"
  echo ""
  if [ -n "$DOMAIN" ]; then
    echo -e "  域名:   ${C}$DOMAIN${N}"
    echo -e "  网站:   ${C}https://$DOMAIN${N}"
    echo -e "  DOH:    ${C}https://$DOMAIN$DOH_PATH?name=google.com${N}"
  else
    echo -e "  模式:   IP 直连"
    echo -e "  DOH:    ${C}http://${SERVER_IP}:${PORT}/dns-query?name=google.com${N}"
  fi

  echo ""
  echo -e "${C}  ═══ DOH 测试 ═══${N}"
  echo ""
  local test_url="http://127.0.0.1:8054/dns-query?name=google.com&type=A"
  local result=$(curl -sf "$test_url" 2>/dev/null)
  if echo "$result" | grep -q "Answer" 2>/dev/null; then
    local ip=$(echo "$result" | grep -oP '"data"\s*:\s*"\K[^"]+' | head -1)
    ok "DOH 正常 → google.com = $ip"
  else
    wr "DOH 未响应"
  fi
  echo ""
}

# ─── 卸载 ────────────────────────────────────────────────────────
uninstall_all() {
  load_env
  echo ""
  echo -e "${R}  ⚠  即将删除所有组件${N}"
  echo ""
  echo -n "  确认卸载？[y/N] "
  read -r CONFIRM </dev/tty 2>/dev/null || CONFIRM="n"
  [[ ! "$CONFIRM" =~ ^[Yy]$ ]] && return

  p "停止 Docker..."
  if [ -f "$DOH_DIR/docker-compose.yml" ]; then
    cd "$DOH_DIR" && docker compose down 2>/dev/null || docker-compose down 2>/dev/null || true
  fi
  docker rm -f doh-coredns doh-server 2>/dev/null || true

  if [ -n "$DOMAIN" ]; then
    p "清理 Caddy..."
    systemctl stop caddy 2>/dev/null || true
    echo ':80 { respond "OK" }' > /etc/caddy/Caddyfile 2>/dev/null || true
    rm -rf "${WEB_DIR}/${DOMAIN}" 2>/dev/null || true
    systemctl start caddy 2>/dev/null || true
  fi

  p "删除文件..."
  rm -rf "$DIR"

  p "重载 systemd..."
  systemctl daemon-reload

  echo ""
  ok "卸载完成"
  echo ""
}

# ─── 内部函数 ────────────────────────────────────────────────────

install_deps() {
  p "安装依赖..."

  # Docker
  if ! command -v docker &>/dev/null; then
    p "安装 Docker..."
    curl -fsSL https://get.docker.com </dev/null | sh 2>/dev/null
    systemctl enable docker --quiet 2>/dev/null
    systemctl start docker 2>/dev/null
  fi
  ok "Docker"

  # Caddy（域名模式需要）
  # 域名安装时单独装
}

setup_doh() {
  p "配置 DOH..."
  mkdir -p "$DOH_DIR"

  cat > "$DOH_DIR/docker-compose.yml" << 'EOF'
services:
  coredns:
    image: coredns/coredns:1.12.3
    container_name: doh-coredns
    restart: unless-stopped
    command: -conf /Corefile
    volumes:
      - ./Corefile:/Corefile:ro
    ports:
      - "127.0.0.1:8053:8053/udp"
      - "127.0.0.1:8053:8053/tcp"
  doh-server:
    image: satishweb/doh-server:latest
    container_name: doh-server
    restart: unless-stopped
    environment:
      UPSTREAM_DNS_SERVER: udp:127.0.0.1:8053
      DOH_HTTP_PREFIX: /dns-query
      DOH_SERVER_LISTEN: 127.0.0.1:8054
      DOH_SERVER_TIMEOUT: 10
      DOH_SERVER_TRIES: 3
      DOH_SERVER_VERBOSE: "false"
    network_mode: host
EOF

  cat > "$DOH_DIR/Corefile" << 'EOF'
.:8053 {
    errors
    log
    forward . 1.1.1.1 1.0.0.1 8.8.8.8 8.8.4.4
    cache 300
}
EOF

  cd "$DOH_DIR"
  docker compose pull -q 2>/dev/null || docker-compose pull -q 2>/dev/null || true
  docker compose up -d 2>/dev/null || docker-compose up -d 2>/dev/null
  ok "DOH 已启动"
}

install_caddy() {
  if command -v caddy &>/dev/null; then return; fi
  p "安装 Caddy..."
  if command -v apt-get &>/dev/null; then
    apt-get update -qq </dev/null 2>/dev/null
    apt-get install -y -qq debian-keyring debian-archive-keyring apt-transport-https </dev/null 2>/dev/null
    curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/gpg.key' </dev/null | gpg --dearmor -o /usr/share/keyrings/caddy-stable-archive-keyring.gpg 2>/dev/null
    curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt' </dev/null | tee /etc/apt/sources.list.d/caddy-stable.list >/dev/null
    apt-get update -qq </dev/null 2>/dev/null
    apt-get install -y -qq caddy </dev/null 2>/dev/null
  elif command -v dnf &>/dev/null; then
    dnf copr enable @caddy/caddy -y 2>/dev/null
    dnf install -y -q caddy 2>/dev/null
  else
    local ARCH=$(uname -m); case "$ARCH" in x86_64|amd64) ARCH="amd64";; aarch64|arm64) ARCH="arm64";; esac
    curl -sSL "https://caddyserver.com/api/download?os=linux&arch=${ARCH}" </dev/null -o /usr/bin/caddy
    chmod +x /usr/bin/caddy
  fi
  ok "Caddy"
}

setup_caddy() {
  local domain="$1" doh_path="$2"
  install_caddy

  mkdir -p /var/log/caddy "${WEB_DIR}/${domain}"

  cat > /etc/caddy/Caddyfile << EOF
${domain} {
    encode gzip zstd

    log {
        output file /var/log/caddy/${domain}-access.log {
            roll_size 20MiB
            roll_keep 10
            roll_keep_for 336h
        }
        format json
    }

    @old_doh path /dns-query
    respond @old_doh 404

    handle ${doh_path}* {
        uri replace ${doh_path} /dns-query
        reverse_proxy 127.0.0.1:8054
    }

    root * ${WEB_DIR}/${domain}
    file_server
    try_files {path} /index.html
}
EOF

  systemctl enable caddy --quiet 2>/dev/null
  systemctl restart caddy
  ok "Caddy 配置完成"
}

setup_decoy() {
  local domain="$1"
  if [ -f "$DIR/decoy/index.html" ]; then
    cp "$DIR/decoy/index.html" "${WEB_DIR}/${domain}/index.html"
  else
    curl -sSL "https://raw.githubusercontent.com/kzb12580/sub-store/main/decoy/index.html" \
      -o "${WEB_DIR}/${domain}/index.html" 2>/dev/null || true
  fi
  ok "伪装网站"
}

setup_firewall() {
  local ssh_port="$1"; shift
  p "配置防火墙..."
  if ! command -v ufw &>/dev/null; then
    if command -v apt-get &>/dev/null; then apt-get install -y -qq ufw </dev/null 2>/dev/null; fi
  fi
  if command -v ufw &>/dev/null; then
    ufw default deny incoming </dev/null 2>/dev/null
    ufw default allow outgoing </dev/null 2>/dev/null
    ufw status | grep -q "$ssh_port/tcp" || ufw allow "$ssh_port/tcp" comment "SSH" </dev/null 2>/dev/null
    for port in "$@"; do
      ufw status | grep -q "$port/tcp" || ufw allow "$port/tcp" comment "Service" </dev/null 2>/dev/null
    done
    if ! ufw status | grep -q "Status: active"; then
      echo "y" | ufw --force enable </dev/null 2>/dev/null || true
    fi
    ufw reload 2>/dev/null || true
    ok "防火墙就绪（SSH:$ssh_port 端口:$(echo "$@" | tr ' ' ',')）"
  fi

  # 快捷命令
  mkdir -p /opt/doh-server
  curl -sSL "https://raw.githubusercontent.com/kzb12580/sub-store/main/manage.sh" \
    -o /opt/doh-server/manage.sh 2>/dev/null || true
  chmod +x /opt/doh-server/manage.sh 2>/dev/null
  cat > /usr/local/bin/k << 'KEOF'
#!/bin/bash
exec bash /opt/doh-server/manage.sh "$@"
KEOF
  chmod +x /usr/local/bin/k
}

# ─── 菜单 ────────────────────────────────────────────────────────

show_menu() {
  load_env
  local installed=false
  [ -f "$ENV_FILE" ] && installed=true

  echo ""
  echo -e "${C}╔══════════════════════════════════════════════════════╗${N}"
  echo -e "${C}║           DOH + 安全加固 管理脚本                     ║${N}"
  echo -e "${C}╚══════════════════════════════════════════════════════╝${N}"

  if [ "$installed" = true ]; then
    echo ""
    if [ -n "$DOMAIN" ]; then
      echo -e "  当前: ${G}已安装${N} | 域名: ${C}$DOMAIN${N} | IP: ${C}$SERVER_IP${N}"
    else
      echo -e "  当前: ${G}已安装${N} | IP: ${C}$SERVER_IP:$PORT${N}"
    fi
  fi

  echo ""
  echo -e "  ${Y}1.${N} 安装（IP 直连，无需域名）"
  echo -e "  ${Y}2.${N} 安装（域名 + HTTPS）"
  echo -e "  ${Y}3.${N} 查看状态"
  echo -e "  ${Y}4.${N} 添加/更换域名"
  echo -e "  ${Y}5.${N} 删除域名（回退到 IP 模式）"
  echo -e "  ${Y}6.${N} 重启 DOH"
  echo -e "  ${Y}7.${N} 查看防火墙"
  echo -e "  ${Y}8.${N} 卸载"
  echo -e "  ${Y}0.${N} 退出"
  echo ""
  echo -n "  选择: "
  read -r CHOICE </dev/tty 2>/dev/null || CHOICE=""

  case "$CHOICE" in
    1) install_ip ;;
    2) install_domain ;;
    3) show_status ;;
    4) add_domain ;;
    5) remove_domain ;;
    6)
      if [ -f "$DOH_DIR/docker-compose.yml" ]; then
        cd "$DOH_DIR" && docker compose restart 2>/dev/null || docker-compose restart 2>/dev/null
        ok "DOH 已重启"
      else
        wr "DOH 未安装"
      fi
      ;;
    7)
      echo ""
      ufw status verbose 2>/dev/null || wr "UFW 未安装"
      echo ""
      ;;
    8) uninstall_all ;;
    0) exit 0 ;;
    *) wr "无效选项" ;;
  esac
}

# ─── 入口 ────────────────────────────────────────────────────────
if [ "$1" = "--ip" ]; then
  install_ip
elif [ "$1" = "--domain" ] && [ -n "$2" ]; then
  # 非交互模式
  DOMAIN="$2"
  install_deps
  setup_doh
  setup_caddy "$DOMAIN" "/dns-query"
  setup_decoy "$DOMAIN"
  setup_firewall 307 80 443
  mkdir -p "$DIR"
  cat > "$ENV_FILE" << EOF
SERVER_IP=$(get_ip)
PORT=80
DOH_PATH=/dns-query
SSH_PORT=307
DOMAIN=$DOMAIN
EOF
  echo ""
  ok "安装完成: https://$DOMAIN"
  echo ""
else
  show_menu
fi
