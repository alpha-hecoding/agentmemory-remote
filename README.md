# agentmemory 远程部署

单容器自包含部署：iii 引擎（绑 0.0.0.0:3111）+ agentmemory worker 同容器运行，
仅发布 REST 端口，供远程机器上的 agent 通过 MCP / REST 接入。

## 目录内容

| 文件 | 说明 |
|---|---|
| `Dockerfile` | 基于官方 `deploy/coolify/Dockerfile` 改造（node:22-slim + 钉死 iii 0.22.1） |
| `entrypoint.sh` | 首次启动：覆写 iii 配置为 0.0.0.0 + /data 绝对路径，生成 HMAC 密钥到 `/data/.hmac`，gosu 降权到 node 用户 |
| `docker-compose.yml` | 服务定义，发布 3111 |
| `.env.example` | 配置模板，复制为 `.env` |

## 部署

```bash
cp .env.example .env   # 按需配置（默认全留空即可）
docker compose up -d --build
```

## 获取密钥（只打印一次）

```bash
docker compose logs | grep -o 'AGENTMEMORY_SECRET=[0-9a-f]\{64\}'
```

或直接读卷（容器内 root 不可直接读，需进容器）：

```bash
docker compose exec agentmemory cat /data/.hmac
```

**轮换密钥**：`docker compose down` 后删除卷中 `.hmac`，重启即重新生成（或 .env 里预置 `AGENTMEMORY_SECRET`）。

## 验证

```bash
# 本机
curl -fsS http://localhost:3111/agentmemory/livez
# 远程
curl -fsS http://<HOST>:3111/agentmemory/livez
```

## 远程 agent 接入（其它机器）

MCP 配置（Claude Code 的 `~/.claude.json` / settings、Cursor `mcp.json` 等）：

```json
"mcpServers": {
  "agentmemory": {
    "command": "npx",
    "args": ["-y", "@agentmemory/mcp"],
    "env": {
      "AGENTMEMORY_URL": "http://<HOST>:3111",
      "AGENTMEMORY_SECRET": "<64位密钥>"
    }
  }
}
```

- shim 能通过 `AGENTMEMORY_URL` 连上服务时，暴露完整 54 个工具；
  连不上时退化为 7 工具本地模式（`AGENTMEMORY_TOOLS` 是服务端变量，写在 shim env 里无效）。
- REST 直连示例：

```bash
# 写入记忆
curl -fsS -X POST http://<HOST>:3111/agentmemory/remember \
  -H "Authorization: Bearer <密钥>" -H 'Content-Type: application/json' \
  -d '{"content":"远程写入测试","concepts":["test"]}'

# 删除指定记忆
curl -fsS -X POST http://<HOST>:3111/agentmemory/forget \
  -H "Authorization: Bearer <密钥>" -H 'Content-Type: application/json' \
  -d '{"memoryId":"<memory_id>"}'
```

## 安全须知

- **明文 HTTP + Bearer 认证**：密钥和记忆内容不加密传输。跨公网使用时务必加反向代理 TLS
  （Caddy/Nginx，容器只 `expose` 3111 不 `ports`），并保证密钥不泄漏。
- 防火墙/安全组：只放行可信来源的 3111 端口。
- viewer (3113) 只发布到宿主机 loopback（`127.0.0.1:3113`），本机浏览器直接访问
  `http://localhost:3113`。配置要点（compose 已配好）：
  - `AGENTMEMORY_VIEWER_HOST=0.0.0.0`：viewer 默认只绑容器 loopback，docker 端口映射
    走容器主网卡，不设置则宿主机访问不到（连接被重置）
  - 非 loopback 绑定强制要求 `AGENTMEMORY_SECRET`（entrypoint 已生成）+ 显式
    `VIEWER_ALLOWED_HOSTS`，且**值必须带端口**（Host 头校验按完整 `host:port` 匹配）
  - 远程机器访问 viewer：`ssh -L 3113:127.0.0.1:3113 <host>` 后浏览器开 localhost:3113
- `/data` 卷内含 `.hmac` 密钥和全部记忆数据，备份时一并备份。

## 升级

修改 Dockerfile 的 `AGENTMEMORY_VERSION` / `III_VERSION`（两者必须同步升级，
引擎与 SDK wire protocol 绑定），然后：

```bash
docker compose up -d --build
```

## 数据备份/恢复

```bash
# 导出（在运行中执行）
SECRET=$(docker compose exec -T agentmemory cat /data/.hmac)
curl -fsS -H "Authorization: Bearer $SECRET" \
  http://localhost:3111/agentmemory/export > backup.json

# 导入
jq -n --slurpfile d backup.json '{exportData: $d[0], strategy: "merge"}' | \
  curl -fsS -H "Authorization: Bearer $SECRET" -X POST \
  -H 'Content-Type: application/json' http://localhost:3111/agentmemory/import -d @-
```
