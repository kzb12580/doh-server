# DOH Server

> **⚠️ 安全警告**：不建议直接使用 `curl | bash` 方式安装。请先下载脚本审查内容，确认无误后再执行。

一键部署 DNS-over-HTTPS + 服务器安全加固 + 伪装网站。通用脚本，任意 Linux VPS 适用。

## 安全安装（推荐）

```bash
# 1. 下载脚本并审查
curl -sSL -o manage.sh https://raw.githubusercontent.com/kzb12580/doh-server/main/manage.sh
nano manage.sh  # 或 cat manage.sh 审查内容

# 2. 校验（如有 checksum 文件）
# sha256sum -c manage.sh.sha256

# 3. 执行安装
sudo bash manage.sh
```

## 快速安装

**交互式（推荐）：**
```bash
curl -sSL -o manage.sh https://raw.githubusercontent.com/kzb12580/doh-server/main/manage.sh
sudo bash manage.sh
```

**IP 直连模式：**
```bash
curl -sSL -o manage.sh https://raw.githubusercontent.com/kzb12580/doh-server/main/manage.sh
sudo bash manage.sh --ip
```

**域名模式（自动 HTTPS）：**
```bash
curl -sSL -o manage.sh https://raw.githubusercontent.com/kzb12580/doh-server/main/manage.sh
sudo bash manage.sh --domain sub.example.com
```

## 命令行参数

```bash
sudo bash manage.sh              # 交互式菜单
sudo bash manage.sh --ip         # IP 直连模式安装
sudo bash manage.sh --domain FQDN  # 域名 + HTTPS 模式安装
sudo bash manage.sh --version    # 显示版本
sudo bash manage.sh --help       # 显示帮助
```

## 管理

安装后运行管理脚本：

```bash
sudo bash /opt/doh-server/manage.sh
```

```
╔══════════════════════════════════════════════════════════╗
║           DOH + 安全加固 管理脚本 v1.0.2                  ║
╚══════════════════════════════════════════════════════════╝

  1. 安装（IP 直连，无需域名）
  2. 安装（域名 + HTTPS）
  3. 查看状态
  4. 添加/更换域名
  5. 删除域名（回退到 IP 模式）
  6. 重启 DOH
  7. 查看防火墙
  8. 卸载
  0. 退出
```

## 部署内容

| 组件 | 说明 |
|------|------|
| **CoreDNS** | 上游 DNS 解析（Docker） |
| **DOH Server** | DNS-over-HTTPS 端点（Docker） |
| **Caddy** | 反向代理 + 自动 HTTPS + 证书管理（域名模式） |
| **UFW** | 防火墙，默认拒绝入站，仅开放必要端口 |
| **伪装网站** | 环保公益页面（域名模式） |

## DOH 使用

安装后在客户端配置 DOH 地址：

```
# IP 模式
http://你的IP:端口/dns-query

# 域名模式
https://你的域名/dns-query
```

## 管理命令

```bash
sudo bash /opt/doh-server/manage.sh          # 打开管理菜单
cd /opt/doh-server/doh && docker compose restart  # 重启 DOH
systemctl reload caddy                      # 重载 Caddy
ufw status                                  # 查看防火墙
tail -f /tmp/doh-server-setup.log           # 查看安装日志
```

## 卸载

```bash
sudo bash /opt/doh-server/manage.sh
# 选择 8（需要二次确认）
```

## 安全特性

- ✅ 远程文件下载使用安全方法（先存临时文件再移动，支持校验和验证）
- ✅ Docker 安装脚本下载到临时文件后执行，不通过管道直接运行
- ✅ GPG 密钥下载后本地处理，不使用 `curl | gpg` 管道
- ✅ Caddy 二进制从 GitHub Releases 下载，固定版本号
- ✅ `.env` 配置文件安全解析（白名单字段，不执行任意代码）
- ✅ 域名输入格式校验，防止配置注入
- ✅ DOH 路径格式校验，防止特殊字符注入
- ✅ 端口范围校验（1-65535）
- ✅ 防火墙规则在启用前验证 SSH 端口规则已正确添加
- ✅ `.env` 配置文件权限设为 600（仅 root 可读写）
- ✅ 安装前自动备份现有配置
- ✅ 严格的错误处理（`set -euo pipefail`）
- ✅ Docker 镜像拉取失败时明确报错，不静默继续
- ✅ 伪装网站添加 `noindex, nofollow` 防止搜索引擎收录
- ✅ 卸载需二次确认

## 常见问题

**Q: 防火墙启用后 SSH 连不上了？**
A: 检查 `.env` 中的 `SSH_PORT` 是否与你实际使用的 SSH 端口一致，或临时通过云控制台 VNC 恢复。

**Q: Docker 安装失败？**
A: 请检查网络连接，或手动安装 Docker：`curl -fsSL https://get.docker.com -o get-docker.sh && sudo bash get-docker.sh`

**Q: Caddy 无法获取 HTTPS 证书？**
A: 请确保域名 A 记录已正确指向服务器 IP，且 80/443 端口未被占用。

## License

MIT License - see [LICENSE](LICENSE) file for details.
