# Sub-Store

轻量级代理订阅管理与配置转换服务。

## 功能

- **多协议解析**：VMess、VLESS、Trojan、Shadowsocks、Hysteria2、TUIC
- **配置转换**：一键生成 Clash / Sing-box 配置
- **DOH 解析**：DNS-over-HTTPS 解析，避免 DNS 污染
- **节点去重**：自动去除重复节点
- **延迟测试**：单个/批量 TCP 延迟测试
- **批量导入**：支持批量导入订阅链接
- **导入导出**：订阅数据备份与恢复
- **自动刷新**：定时自动刷新订阅
- **暗色主题**：响应式 Web UI

## 快速开始

### 一键安装（推荐）

```bash
# 下载安装脚本
curl -sSL https://raw.githubusercontent.com/kzb12580/sub-store/main/install.sh -o install.sh

# 带域名安装（自动配置 Nginx + SSL）
bash install.sh --domain sub.example.com

# 仅本地使用
bash install.sh --port 8888 --skip-nginx

# 查看帮助
bash install.sh --help
```

### 手动编译

```bash
git clone https://github.com/kzb12580/sub-store.git
cd sub-store
go build -o sub-store .
./sub-store -port 8888
```

### Docker

```bash
docker run -d --name sub-store \
  -p 8888:8888 \
  -v sub-store-data:/app/data \
  ghcr.io/kzb12580/sub-store:latest
```

## API

| 接口 | 方法 | 说明 |
|------|------|------|
| `/api/subscriptions` | GET | 列出所有订阅 |
| `/api/subscriptions` | POST | 添加订阅 |
| `/api/subscriptions/:id` | PUT | 更新订阅 |
| `/api/subscriptions/:id` | DELETE | 删除订阅 |
| `/api/subscriptions/:id/refresh` | POST | 刷新单个订阅 |
| `/api/subscriptions/refresh-all` | POST | 刷新全部订阅 |
| `/api/subscriptions/import` | POST | 批量导入订阅 |
| `/api/subscriptions/import-text` | POST | 导入文本/URI |
| `/api/subscriptions/export` | GET | 导出备份 |
| `/api/nodes` | GET | 列出节点 |
| `/api/nodes/stats` | GET | 节点统计 |
| `/api/nodes/ping` | POST | 测试单个节点延迟 |
| `/api/nodes/ping/batch` | POST | 批量延迟测试 |
| `/api/sub/:id/clash` | GET | 生成 Clash 配置 |
| `/api/sub/:id/singbox` | GET | 生成 Sing-box 配置 |
| `/api/sub/all/clash` | GET | 全部节点 Clash 配置 |
| `/api/sub/all/singbox` | GET | 全部节点 Sing-box 配置 |
| `/api/doh/resolve` | POST | DOH 域名解析 |
| `/api/doh/test` | GET | DOH 连接测试 |

## 订阅链接

添加订阅后，点击 **Clash** 或 **Sing-box** 按钮复制订阅链接：

```
https://your-domain/api/sub/{id}/clash
https://your-domain/api/sub/{id}/singbox
https://your-domain/api/sub/all/clash       # 全部合并
https://your-domain/api/sub/all/singbox     # 全部合并
```

## 管理

```bash
# 服务管理
systemctl start sub-store
systemctl stop sub-store
systemctl restart sub-store
systemctl status sub-store

# 查看日志
journalctl -u sub-store -f

# 重新编译
cd /opt/sub-store/src
go build -o /opt/sub-store/sub-store .
systemctl restart sub-store
```

## 技术栈

- **后端**：Go + Gin
- **前端**：原生 HTML/CSS/JS（无框架依赖）
- **存储**：JSON 文件
- **DNS**：Cloudflare / Google DoH

## License

MIT
