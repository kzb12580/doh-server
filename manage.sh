#!/bin/bash
# ═══════════════════════════════════════════════════════════════
#  DOH + 安全加固 管理脚本
#  用法: bash manage.sh
# ═══════════════════════════════════════════════════════════════

# ─── 严格模式：错误立即退出，管道失败传播，未定义变量报错 ───
set -euo pipefail

R='\033[0;31m'; G='\033[0;32m'; Y='\033[1;33m'; B='\033[0;34m'; C='\033[0;36m'; M='\033[0;35m'; N='\033[0m'

# ─── 日志系统 ───
LOG_FILE="/tmp/doh-server-setup.log"
p()  { echo -e "${B}[·]${N} $1"; }
ok() { echo -e "${G}[✓]${N} $1"; echo "[OK] $(date '+%Y-%m-%d %H:%M:%S') $1" >> "$LOG_FILE"; }
wr() { echo -e "${Y}[!]${N} $1"; echo "[WARN] $(date '+%Y-%m-%d %H:%M:%S') $1" >> "$LOG_FILE"; }
die(){ echo -e "${R}[✗]${N} $1"; echo "[ERROR] $(date '+%Y-%m-%d %H:%M:%S') $1" >> "$LOG_FILE"; exit 1; }
info(){ echo -e "    ${N}$1"; echo "    $1" >> "$LOG_FILE"; }

# ─── 全局配置 ───
DIR="/opt/doh-server"
DOH_DIR="$DIR/doh"
WEB_DIR="/var/www"
ENV_FILE="$DIR/.env"
SCRIPT_VERSION="1.0.2"
SCRIPT_NAME="manage.sh"
REPO_OWNER="kzb12580"
REPO_NAME="doh-server"
GITHUB_RAW="https://raw.githubusercontent.com/${REPO_OWNER}/${REPO_NAME}"

# ─── 安全检查 ───
require_root() {
  if [[ $EUID -ne 0 ]]; then
    die "此脚本需要 root 权限。请使用 sudo $0"
  fi
}

require_linux() {
  if [[ ! -f /etc/os-release ]]; then
    die "仅支持 Linux 系统"
  fi
}

# ─── 安全的远程文件下载（带校验和） ───
SAFE_DOWNLOADS_DIR="/tmp/doh-server-downloads"

download_safe() {
  local url="$1"
  local dest="$2"
  local expect_sha256="${3:-}"
  local label="${4:-file}"

  mkdir -p "$SAFE_DOWNLOADS_DIR"
  local tmp_file
  tmp_file=$(mktemp "$SAFE_DOWNLOADS_DIR/XXXXXX")

  p "下载 ${label}..."
  if ! curl -fsSL --connect-timeout 10 --retry 3 --retry-delay 2 "$url" -o "$tmp_file"; then
    die "下载 ${label} 失败: $url"
  fi

  if [[ -n "$expect_sha256" ]]; then
    local actual_sha
    actual_sha=$(sha256sum "$tmp_file" | awk '{print $1}')
    if [[ "$actual_sha" != "$expect_sha256" ]]; then
      die "校验和不匹配！期望: $expect_sha256, 实际: $actual_sha"
    fi
    ok "校验和验证通过"
  fi

  mv "$tmp_file" "$dest"
  ok "${label} 下载完成: $dest"
}

download_safe_no_fail() {
  local url="$1"
  local dest="$2"
  local label="${3:-file}"

  mkdir -p "$SAFE_DOWNLOADS_DIR"
  local tmp_file
  tmp_file=$(mktemp "$SAFE_DOWNLOADS_DIR/XXXXXX")

  if curl -fsSL --connect-timeout 10 --retry 3 --retry-delay 2 "$url" -o "$tmp_file" 2>/dev/null; then
    mv "$tmp_file" "$dest"
    ok "${label} 下载完成"
    return 0
  else
    rm -f "$tmp_file" 2>/dev/null || true
    return 1
  fi
}

# ─── IP 检测 ───
get_ip() {
  curl -4 -s --connect-timeout 5 ifconfig.me 2>/dev/null || \
  curl -4 -s --connect-timeout 5 ip.sb 2>/dev/null || \
  curl -4 -s --connect-timeout 5 api.ipify.org 2>/dev/null || echo ""
}

# ─── 字符串 trim（纯 bash，不调用外部命令） ───
trim() {
  local s="$1"
  s="${s#"${s%%[![:space:]]*}"}"   # 去首部空白
  s="${s%"${s##*[![:space:]]}"}"   # 去尾部空白
  printf '%s' "$s"
}

load_env() {
  SERVER_IP=""; PORT=80; DOH_PATH="/dns-query"; SSH_PORT=307; DOMAIN=""
  if [[ -f "$ENV_FILE" ]]; then
    while IFS='=' read -r key val; do
      [[ -z "$key" || "$key" =~ ^[[:space:]]*# ]] && continue
      key=$(trim "$key")
      val=$(trim "$val")
      case "$key" in
        SERVER_IP) SERVER_IP="$val" ;;
        PORT) PORT="$val" ;;
        DOH_PATH) DOH_PATH="$val" ;;
        SSH_PORT) SSH_PORT="$val" ;;
        DOMAIN) DOMAIN="$val" ;;
        SCRIPT_VERSION) SCRIPT_VERSION="$val" ;;
      esac
    done < "$ENV_FILE"
  fi
  [ -z "$SERVER_IP" ] && SERVER_IP=$(get_ip)
}

# ─── 域名校验 ───
validate_domain() {
  local domain="$1"
  if [[ ! "$domain" =~ ^[a-zA-Z0-9]([a-zA-Z0-9\-]*[a-zA-Z0-9])?(\.[a-zA-Z0-9]([a-zA-Z0-9\-]*[a-zA-Z0-9])?)*$ ]]; then
    die "域名格式无效: $domain"
  fi
  if [[ "$domain" =~ \\.\\. ]]; then
    die "域名中包含连续点号"
  fi
  if [[ ${#domain} -gt 253 ]]; then
    die "域名长度超过 253 字符"
  fi
}

# ─── 端口校验 ───
validate_port() {
  local port="$1"
  local label="${2:-端口}"
  if [[ ! "$port" =~ ^[0-9]+$ ]]; then
    die "$label 必须是数字: $port"
  fi
  if (( port < 1 || port > 65535 )); then
    die "$label 必须在 1-65535 范围内: $port"
  fi
}

# ─── 备份 ───
BACKUP_DIR="/tmp/doh-server-backup-$(date +%Y%m%d%H%M%S)"

backup_before_change() {
  if [[ -d "$DIR" ]]; then
    p "备份当前配置到 $BACKUP_DIR..."
    mkdir -p "$BACKUP_DIR"
    cp -a "$DIR" "$BACKUP_DIR/" 2>/dev/null || true
    cp /etc/caddy/Caddyfile "$BACKUP_DIR/Caddyfile.bak" 2>/dev/null || true
    ok "备份完成"
  fi
}

# ═══════════════════════════════════════════════════════════════
#  安装流程
# ═══════════════════════════════════════════════════════════════

install_deps() {
  p "安装依赖..."

  # ─── Docker ───
  if ! command -v docker &>/dev/null; then
    p "安装 Docker..."
    local docker_script
    docker_script=$(mktemp /tmp/doh-docker-install.XXXXXX.sh)

    if curl -fsSL --connect-timeout 30 https://get.docker.com -o "$docker_script"; then
      if bash "$docker_script"; then
        ok "Docker 安装完成"
      else
        die "Docker 安装脚本执行失败"
      fi
      rm -f "$docker_script"
    else
      die "无法下载 Docker 安装脚本"
    fi

    systemctl enable docker --quiet 2>/dev/null || true
    systemctl start docker 2>/dev/null || true

    # 验证 Docker 是否可用
    if ! docker info &>/dev/null; then
      die "Docker 安装后无法启动，请手动检查"
    fi
    ok "Docker 运行正常"
  else
    ok "Docker 已安装"
  fi

  # 验证 Docker 版本
  local docker_ver
  docker_ver=$(docker --version 2>/dev/null | grep -oP '[\d.]+' | head -1 || echo "unknown")
  info "Docker 版本: $docker_ver"
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
    networks:
      - doh-net
    extra_hosts:
      - "host.docker.internal:host-gateway"
  doh-server:
    image: satishweb/doh-server:latest
    container_name: doh-server
    restart: unless-stopped
    environment:
      UPSTREAM_DNS_SERVER: udp:127.0.0.1:8053
      DOH_HTTP_PREFIX: /dns-query
      DOH_SERVER_LISTEN: 0.0.0.0:8054
      DOH_SERVER_TIMEOUT: 10
      DOH_SERVER_TRIES: 3
      DOH_SERVER_VERBOSE: "false"
    networks:
      - doh-net
    depends_on:
      - coredns
networks:
  doh-net:
    name: doh-network
    driver: bridge
EOF

  cat > "$DOH_DIR/Corefile" << 'EOF'
.:8053 {
    errors
    log
    forward . 1.1.1.1 1.0.0.1 8.8.8.8 8.8.4.4
    cache 300
}
EOF

  cd "$DOH_DIR" || die "无法进入 DOH 目录: $DOH_DIR"
  if ! docker compose pull -q 2>/dev/null; then
    if ! docker-compose pull -q; then
      die "Docker 镜像拉取失败，请检查网络连接"
    fi
  fi
  docker compose up -d 2>/dev/null || docker-compose up -d

  # 验证容器启动
  sleep 3
  if docker ps --format '{{.Names}}' 2>/dev/null | grep -q "doh-coredns"; then
    ok "CoreDNS 已启动"
  else
    wr "CoreDNS 可能未启动，请检查 docker logs doh-coredns"
  fi

  if docker ps --format '{{.Names}}' 2>/dev/null | grep -q "doh-server"; then
    ok "DOH Server 已启动"
  else
    wr "DOH Server 可能未启动，请检查 docker logs doh-server"
  fi
}

# ═══════════════════════════════════════════════════════════════
#  Caddy 配置（域名模式）
# ═══════════════════════════════════════════════════════════════

install_caddy() {
  if command -v caddy &>/dev/null; then
    local caddy_ver
    caddy_ver=$(caddy version 2>/dev/null || echo "unknown")
    info "Caddy 版本: $caddy_ver"
    ok "Caddy 已安装"
    return
  fi

  p "安装 Caddy..."
  if command -v apt-get &>/dev/null; then
    apt-get update -qq </dev/null 2>/dev/null || true
    apt-get install -y -qq debian-keyring debian-archive-keyring apt-transport-https </dev/null 2>/dev/null || true
    local caddy_gpg_key
    caddy_gpg_key=$(mktemp "$SAFE_DOWNLOADS_DIR/XXXXXX.gpg")
    if curl -fsSL --connect-timeout 10 --retry 3 'https://dl.cloudsmith.io/public/caddy/stable/gpg.key' -o "$caddy_gpg_key" 2>/dev/null; then
      gpg --dearmor -o /usr/share/keyrings/caddy-stable-archive-keyring.gpg < "$caddy_gpg_key" 2>/dev/null || true
    fi
    rm -f "$caddy_gpg_key"
    curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt' </dev/null | tee /etc/apt/sources.list.d/caddy-stable.list >/dev/null || true
    apt-get update -qq </dev/null 2>/dev/null || true
    if ! apt-get install -y -qq caddy </dev/null 2>/dev/null; then
      wr "apt 安装 Caddy 失败，尝试直接从二进制安装"
      install_caddy_binary
    fi
  elif command -v dnf &>/dev/null; then
    dnf copr enable @caddy/caddy -y 2>/dev/null || true
    if ! dnf install -y -q caddy 2>/dev/null; then
      wr "dnf 安装 Caddy 失败，尝试直接从二进制安装"
      install_caddy_binary
    fi
  else
    install_caddy_binary
  fi
  ok "Caddy 安装完成"
}

install_caddy_binary() {
  local ARCH
  ARCH=$(uname -m)
  case "$ARCH" in
    x86_64|amd64) ARCH="amd64" ;;
    aarch64|arm64) ARCH="arm64" ;;
    *) die "不支持的架构: $ARCH" ;;
  esac

  local CADDY_VERSION="2.10.0"
  p "从二进制下载 Caddy ${CADDY_VERSION} ($ARCH)..."
  local caddy_url="https://github.com/caddyserver/caddy/releases/download/v${CADDY_VERSION}/caddy_${CADDY_VERSION}_linux_${ARCH}.tar.gz"
  download_safe "$caddy_url" \
    "/tmp/doh-server-downloads/caddy-${ARCH}.tar.gz" \
    "" \
    "Caddy v${CADDY_VERSION} 二进制包"

  local tarball="/tmp/doh-server-downloads/caddy-${ARCH}.tar.gz"
  if ! command -v tar &>/dev/null; then
    die "无法解压 Caddy 包：需要 tar 命令。请运行 apt install tar 或 dnf install tar"
  fi

  tar -xzf "$tarball" -C /tmp/doh-server-downloads/ 2>/dev/null
  if [[ -f /tmp/doh-server-downloads/caddy ]]; then
    mv /tmp/doh-server-downloads/caddy /usr/local/bin/caddy
    chmod +x /usr/local/bin/caddy
    ok "Caddy 二进制安装完成"
  else
    die "解压后未找到 caddy 二进制文件"
  fi
}

setup_caddy() {
  local domain="$1" doh_path="$2"

  # 验证域名（已在外部函数校验，此处二次确认）
  validate_domain "$domain"

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

  # 语法检查
  if command -v caddy &>/dev/null; then
    local caddy_validate_output
    caddy_validate_output=$(caddy validate --config /etc/caddy/Caddyfile 2>&1 || true)
    if ! echo "$caddy_validate_output" | grep -q "Valid configuration"; then
      die "Caddyfile 语法校验失败:\n$caddy_validate_output"
    fi
  fi

  systemctl enable caddy --quiet 2>/dev/null || true
  systemctl restart caddy

  sleep 1
  if systemctl is-active --quiet caddy 2>/dev/null; then
    ok "Caddy 配置完成并运行中"
  else
    wr "Caddy 配置完成但可能未运行，请检查 systemctl status caddy"
  fi
}

setup_decoy() {
  local domain="$1"
  validate_domain "$domain"
  if [[ -f "$DIR/decoy/index.html" ]]; then
    cp "$DIR/decoy/index.html" "${WEB_DIR}/${domain}/index.html"
    ok "伪装网站部署完成"
  else
    # 从远程下载（降级，无校验）
    if download_safe_no_fail "${GITHUB_RAW}/main/decoy/index.html" \
      "${WEB_DIR}/${domain}/index.html" "伪装页面"; then
      ok "伪装网站部署完成"
    else
      wr "伪装页面部署失败（本地文件不存在且远程下载失败）"
    fi
  fi
}

# ═══════════════════════════════════════════════════════════════
#  防火墙配置
# ═══════════════════════════════════════════════════════════════

setup_firewall() {
  local ssh_port="$1"; shift
  p "配置防火墙..."

  validate_port "$ssh_port" "SSH 端口"
  for port in "$@"; do
    validate_port "$port" "服务端口"
  done

  # 检查 ufw 是否存在
  if ! command -v ufw &>/dev/null; then
    if command -v apt-get &>/dev/null; then
      p "安装 UFW..."
      apt-get update -qq </dev/null 2>/dev/null || true
      if ! apt-get install -y -qq ufw </dev/null 2>/dev/null; then
        die "UFW 安装失败，请手动安装后重试"
      fi
      ok "UFW 已安装"
    else
      wr "UFW 不可用，防火墙未配置"
      return
    fi
  fi

  # 保存当前防火墙规则（用于回滚）
  local current_rules
  current_rules=$(ufw status numbered 2>/dev/null || echo "inactive")

  # 确保 SSH 端口被允许
  ufw default deny incoming </dev/null 2>/dev/null || true
  ufw default allow outgoing </dev/null 2>/dev/null || true

  # 先添加规则再启用，避免竞态条件
  ufw allow "$ssh_port/tcp" comment "SSH" </dev/null 2>/dev/null || true
  for port in "$@"; do
    ufw allow "$port/tcp" comment "Service" </dev/null 2>/dev/null || true
  done

  # 确认 SSH 端口规则已添加
  if ! ufw status 2>/dev/null | grep -q "${ssh_port}/tcp"; then
    die "SSH 端口 $ssh_port 防火墙规则添加失败，可能已存在冲突规则。当前规则:\n$current_rules"
  fi

  # 启用防火墙（在规则确认无误后）
  if ! ufw status 2>/dev/null | grep -q "Status: active"; then
    p "启用防火墙..."
    if echo "y" | ufw --force enable </dev/null 2>/dev/null; then
      ok "防火墙已启用"
    else
      die "防火墙启用失败！已保留原有规则，请手动检查"
    fi
  fi

  ufw reload 2>/dev/null || true
  ok "防火墙就绪（SSH:$ssh_port 端口:$(echo "$@" | tr ' ' ',')）"
}

# ═══════════════════════════════════════════════════════════════
#  安装（IP 模式）
# ═══════════════════════════════════════════════════════════════

install_ip() {
  require_root
  require_linux

  echo ""
  echo -e "${C}  安装 DOH（IP 直连模式）${N}"
  echo ""

  local IP
  IP=$(get_ip)
  if [[ -z "$IP" ]]; then
    die "无法检测服务器 IP，请检查网络连接"
  fi
  info "检测到 IP: $IP"

  local PORT_IN
  echo -n "  服务端口 [80]: "
  read -r PORT_IN </dev/tty 2>/dev/null || PORT_IN=""
  PORT_IN=${PORT_IN:-80}
  validate_port "$PORT_IN" "服务端口"

  local SSH_IN
  echo -n "  SSH 端口 [307]: "
  read -r SSH_IN </dev/tty 2>/dev/null || SSH_IN=""
  SSH_IN=${SSH_IN:-307}
  validate_port "$SSH_IN" "SSH 端口"

  echo ""
  p "开始安装..."

  backup_before_change

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
  chmod 600 "$ENV_FILE"
  chown root:root "$ENV_FILE" 2>/dev/null || true

  # 保存 manage.sh 到目标目录（本地副本）
  if [[ -f "${BASH_SOURCE[0]}" ]]; then
    cp "$(realpath "${BASH_SOURCE[0]}")" "$DIR/manage.sh" 2>/dev/null || true
    chmod +x "$DIR/manage.sh" 2>/dev/null || true
  fi

  # 写入版本信息
  echo "SCRIPT_VERSION=$SCRIPT_VERSION" >> "$ENV_FILE"

  # 清理临时下载文件
  rm -rf "$SAFE_DOWNLOADS_DIR" 2>/dev/null || true

  echo ""
  echo -e "${G}╔══════════════════════════════════════════════════════╗${N}"
  echo -e "${G}║                  ✅ 安装完成！                        ║${N}"
  echo -e "${G}╚══════════════════════════════════════════════════════╝${N}"
  echo ""
  echo -e "  🔒 DOH:  ${C}http://${IP}:${PORT_IN}/dns-query?name=google.com${N}"
  echo ""
  echo -e "  ${Y}日志: ${N}$LOG_FILE"
}

# ═══════════════════════════════════════════════════════════════
#  安装（域名模式）
# ═══════════════════════════════════════════════════════════════

install_domain() {
  require_root
  require_linux

  echo ""
  echo -e "${C}  安装 DOH（域名 + HTTPS 模式）${N}"
  echo ""

  local DOMAIN_IN
  echo -n "  域名: "
  read -r DOMAIN_IN </dev/tty 2>/dev/null || DOMAIN_IN=""
  if [[ -z "$DOMAIN_IN" ]]; then
    die "域名不能为空"
  fi
  validate_domain "$DOMAIN_IN"

  local IP
  IP=$(get_ip)
  if [[ -z "$IP" ]]; then
    die "无法检测服务器 IP，请检查网络连接"
  fi
  info "检测到 IP: $IP"

  local SSH_IN
  echo -n "  SSH 端口 [307]: "
  read -r SSH_IN </dev/tty 2>/dev/null || SSH_IN=""
  SSH_IN=${SSH_IN:-307}
  validate_port "$SSH_IN" "SSH 端口"

  local DOH_PATH_IN
  echo -n "  DOH 路径 [/dns-query]: "
  read -r DOH_PATH_IN </dev/tty 2>/dev/null || DOH_PATH_IN=""
  DOH_PATH_IN=${DOH_PATH_IN:-/dns-query}
  if [[ ! "$DOH_PATH_IN" =~ ^/[a-zA-Z0-9/_-]+$ ]]; then
    die "DOH 路径格式无效（仅允许字母、数字、/、-、_）: $DOH_PATH_IN"
  fi

  echo ""
  p "开始安装..."

  backup_before_change

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
  chmod 600 "$ENV_FILE"
  chown root:root "$ENV_FILE" 2>/dev/null || true
  echo "SCRIPT_VERSION=$SCRIPT_VERSION" >> "$ENV_FILE"

  # 清理临时下载文件
  rm -rf "$SAFE_DOWNLOADS_DIR" 2>/dev/null || true

  # 保存本地副本
  if [[ -f "${BASH_SOURCE[0]}" ]]; then
    cp "$(realpath "${BASH_SOURCE[0]}")" "$DIR/manage.sh" 2>/dev/null || true
    chmod +x "$DIR/manage.sh" 2>/dev/null || true
  fi

  echo ""
  echo -e "${G}╔══════════════════════════════════════════════════════╗${N}"
  echo -e "${G}║                  ✅ 安装完成！                        ║${N}"
  echo -e "${G}╚══════════════════════════════════════════════════════╝${N}"
  echo ""
  echo -e "  🌐 网站:  ${C}https://${DOMAIN_IN}${N}"
  echo -e "  🔒 DOH:   ${C}https://${DOMAIN_IN}${DOH_PATH_IN}?name=google.com${N}"
  echo ""
  echo -e "  ${Y}请确保 ${DOMAIN_IN} 的 A 记录指向 ${IP}${N}"
  echo -e "  ${Y}日志: ${N}$LOG_FILE"
}

# ═══════════════════════════════════════════════════════════════
#  添加域名
# ═══════════════════════════════════════════════════════════════

add_domain() {
  require_root
  load_env

  if [[ -n "$DOMAIN" ]]; then
    wr "当前已绑定域名: $DOMAIN"
    echo -n "  更换域名？[y/N] "
    read -r CONFIRM </dev/tty 2>/dev/null || CONFIRM="n"
    [[ ! "$CONFIRM" =~ ^[Yy]$ ]] && return
  fi

  echo ""
  echo -n "  域名: "
  read -r DOMAIN_IN </dev/tty 2>/dev/null || DOMAIN_IN=""
  if [[ -z "$DOMAIN_IN" ]]; then
    die "域名不能为空"
  fi
  validate_domain "$DOMAIN_IN"

  p "配置 Caddy..."
  backup_before_change

  # 清理旧域名的伪装页面
  local OLD_DOMAIN="$DOMAIN"
  if [[ -n "$OLD_DOMAIN" && -d "${WEB_DIR}/${OLD_DOMAIN}" ]]; then
    rm -rf "${WEB_DIR}/${OLD_DOMAIN}" 2>/dev/null || true
    info "已清理旧域名伪装页面: ${WEB_DIR}/${OLD_DOMAIN}"
  fi

  setup_caddy "$DOMAIN_IN" "$DOH_PATH"
  setup_decoy "$DOMAIN_IN"

  # 放行 80/443
  if command -v ufw &>/dev/null; then
    ufw status 2>/dev/null | grep -q "80/tcp"  || ufw allow 80/tcp  comment "HTTP" </dev/null 2>/dev/null || true
    ufw status 2>/dev/null | grep -q "443/tcp" || ufw allow 443/tcp comment "HTTPS" </dev/null 2>/dev/null || true
    ufw reload 2>/dev/null || true
  fi

  # 更新 .env
  if [[ -f "$ENV_FILE" ]]; then
    sed -i "s/^DOMAIN=.*/DOMAIN=$DOMAIN_IN/" "$ENV_FILE"
  fi

  echo ""
  ok "域名已绑定: $DOMAIN_IN"
  echo -e "  🌐 ${C}https://${DOMAIN_IN}${N}"
  echo -e "  🔒 ${C}https://${DOMAIN_IN}${DOH_PATH}?name=google.com${N}"
  echo ""
}

# ═══════════════════════════════════════════════════════════════
#  删除域名
# ═══════════════════════════════════════════════════════════════

remove_domain() {
  require_root
  load_env

  if [[ -z "$DOMAIN" ]]; then
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

  if [[ -f "$ENV_FILE" ]]; then
    sed -i "s/^DOMAIN=.*/DOMAIN=/" "$ENV_FILE"
    chmod 600 "$ENV_FILE"
  fi

  ok "域名已解绑"
}

# ═══════════════════════════════════════════════════════════════
#  查看状态
# ═══════════════════════════════════════════════════════════════

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
  if [[ -n "$DOMAIN" ]]; then
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
  local result
  result=$(curl -sf --connect-timeout 5 "$test_url" 2>/dev/null || echo "")
  if echo "$result" | grep -q "Answer" 2>/dev/null; then
    local ip
    ip=$(echo "$result" | grep -oP '"data"\s*:\s*"\K[^"]+' | head -1 || echo "unknown")
    ok "DOH 正常 → google.com = $ip"
  else
    wr "DOH 未响应"
  fi
  echo ""
}

# ═══════════════════════════════════════════════════════════════
#  卸载
# ═══════════════════════════════════════════════════════════════

uninstall_all() {
  require_root
  load_env

  echo ""
  echo -e "${R}  ⚠  即将删除所有组件${N}"
  echo -e "${R}  ⚠  此操作不可恢复！${N}"
  echo ""

  # 显示将要删除的内容
  if [[ -d "$DIR" ]]; then
    echo -e "  将要删除: ${C}$DIR${N}"
    du -sh "$DIR" 2>/dev/null | sed 's/^/    /'
  fi
  if [[ -f /etc/caddy/Caddyfile ]]; then
    echo -e "  将要删除: ${C}/etc/caddy/Caddyfile${N}"
  fi

  echo ""
  echo -n "  确认卸载？[y/N] "
  read -r CONFIRM </dev/tty 2>/dev/null || CONFIRM="n"
  [[ ! "$CONFIRM" =~ ^[Yy]$ ]] && return

  # 二次确认
  echo -n "  再次确认（输入 YES）: "
  read -r CONFIRM2 </dev/tty 2>/dev/null || CONFIRM2=""
  [[ "$CONFIRM2" != "YES" ]] && die "取消卸载"

  p "停止 Docker..."
  if [[ -f "$DOH_DIR/docker-compose.yml" ]]; then
    (cd "$DOH_DIR" && docker compose down 2>/dev/null || docker-compose down 2>/dev/null) || true
  fi
  docker rm -f doh-coredns doh-server 2>/dev/null || true

  if [[ -n "$DOMAIN" ]]; then
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

  # 清理临时文件
  rm -rf "$SAFE_DOWNLOADS_DIR" 2>/dev/null || true

  echo ""
  ok "卸载完成"
  echo ""
}

# ═══════════════════════════════════════════════════════════════
#  菜单
# ═══════════════════════════════════════════════════════════════

show_menu() {
  require_root
  load_env
  local installed=false
  [[ -f "$ENV_FILE" ]] && installed=true

  echo ""
  echo -e "${C}╔══════════════════════════════════════════════════════════╗${N}"
  echo -e "${C}║           DOH + 安全加固 管理脚本 v${SCRIPT_VERSION}${C}                  ║${N}"
  echo -e "${C}╚══════════════════════════════════════════════════════════╝${N}"

  if [[ "$installed" = true ]]; then
    echo ""
    if [[ -n "$DOMAIN" ]]; then
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
      if [[ -f "$DOH_DIR/docker-compose.yml" ]]; then
        (cd "$DOH_DIR" && docker compose restart 2>/dev/null || docker-compose restart 2>/dev/null) || true
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

# ═══════════════════════════════════════════════════════════════
#  入口
# ═══════════════════════════════════════════════════════════════
if [[ "${1:-}" = "--help" || "${1:-}" = "-h" ]]; then
  echo "DOH + 安全加固 管理脚本 v${SCRIPT_VERSION}"
  echo ""
  echo "用法:"
  echo "  sudo bash manage.sh              交互式菜单"
  echo "  sudo bash manage.sh --ip         IP 直连模式安装"
  echo "  sudo bash manage.sh --domain FQDN  域名 + HTTPS 模式安装"
  echo "  sudo bash manage.sh --version    显示版本"
  echo "  sudo bash manage.sh --help       显示帮助"
  echo ""
  echo "项目: https://github.com/${REPO_OWNER}/${REPO_NAME}"
  exit 0
elif [[ "${1:-}" = "--version" || "${1:-}" = "-v" ]]; then
  echo "doh-server v${SCRIPT_VERSION}"
  exit 0
elif [[ "${1:-}" = "--ip" ]]; then
  install_ip
elif [[ "${1:-}" = "--domain" ]] && [[ -n "${2:-}" ]]; then
  # 非交互模式
  DOMAIN="$2"
  validate_domain "$DOMAIN"

  IP=$(get_ip)
  if [[ -z "$IP" ]]; then
    die "无法检测服务器 IP"
  fi

  backup_before_change
  install_deps
  setup_doh
  setup_caddy "$DOMAIN" "/dns-query"
  setup_decoy "$DOMAIN"
  SSH_PORT_IN="${SSH_PORT:-307}"
  setup_firewall "$SSH_PORT_IN" 80 443

  mkdir -p "$DIR"
  cat > "$ENV_FILE" << EOF
SERVER_IP=$IP
PORT=80
DOH_PATH=/dns-query
SSH_PORT=$SSH_PORT_IN
DOMAIN=$DOMAIN
EOF
  chmod 600 "$ENV_FILE"
  echo "SCRIPT_VERSION=$SCRIPT_VERSION" >> "$ENV_FILE"

  # 清理临时下载文件
  rm -rf "$SAFE_DOWNLOADS_DIR" 2>/dev/null || true

  # 保存本地副本
  if [[ -f "${BASH_SOURCE[0]}" ]]; then
    cp "$(realpath "${BASH_SOURCE[0]}")" "$DIR/manage.sh" 2>/dev/null || true
    chmod +x "$DIR/manage.sh" 2>/dev/null || true
  fi

  echo ""
  ok "安装完成: https://$DOMAIN"
  echo -e "  ${Y}日志: ${N}$LOG_FILE"
  echo ""
else
  show_menu
fi
