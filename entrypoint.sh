#!/bin/sh
# agentmemory 首次启动入口（基于官方 deploy/coolify/entrypoint.sh）
#
# 以 root 运行，以便：
#   1. 覆盖 npm 包自带的 iii-config.yaml（默认绑 127.0.0.1、相对 ./data 路径），
#      改为绑定 0.0.0.0、使用绝对路径 /data —— 容器发布端口必须绑 0.0.0.0
#   2. chown 平台挂载的 /data 卷（平台默认以 root:755 挂载）
#   3. 首次启动生成 HMAC 密钥并持久化到 /data/.hmac（chmod 600），重启不丢失
#
# 之后通过 gosu 降权到非特权 node 用户执行 agentmemory CLI（CLI 会启动 iii 引擎 + worker）。

set -eu

DATA_DIR="${AGENTMEMORY_DATA_DIR:-/data}"
export AGENTMEMORY_DATA_DIR="$DATA_DIR"
HMAC_FILE="${AGENTMEMORY_HMAC_FILE:-/data/.hmac}"
RUN_AS="node:node"
III_CONFIG="/opt/agentmemory/node_modules/@agentmemory/agentmemory/dist/iii-config.yaml"

if [ -z "${MALLOC_ARENA_MAX:-}" ]; then
  export MALLOC_ARENA_MAX=2
fi
cur_nofile="$(ulimit -n)"
if [ "$cur_nofile" != "unlimited" ] && [ "$cur_nofile" -lt 10240 ]; then
  ulimit -n 10240 2>/dev/null || ulimit -n "$(ulimit -H -n)" 2>/dev/null || true
fi

mkdir -p "$DATA_DIR"
chown -R "$RUN_AS" "$DATA_DIR"

cat > "$III_CONFIG" <<'EOF'
workers:
  - name: iii-http
    config:
      port: 3111
      host: 0.0.0.0
      default_timeout: 180000
      cors:
        allowed_origins: ["http://localhost:3111", "http://localhost:3113", "http://127.0.0.1:3111", "http://127.0.0.1:3113"]
        allowed_methods: [GET, POST, PUT, DELETE, OPTIONS]
  - name: iii-state
    config:
      adapter:
        name: kv
        config:
          store_method: file_based
          save_interval_ms: 2000
          file_path: /data/state_store.db
  - name: iii-queue
    config:
      adapter:
        name: builtin
  - name: iii-pubsub
    config:
      adapter:
        name: local
  - name: iii-cron
    config:
      adapter:
        name: kv
  - name: iii-stream
    config:
      port: 3112
      host: 0.0.0.0
      adapter:
        name: kv
        config:
          store_method: file_based
          save_interval_ms: 2000
          file_path: /data/stream_store
  - name: iii-observability
    config:
      enabled: true
      service_name: agentmemory
      exporter: memory
      sampling_ratio: 0.1
      metrics_enabled: true
      logs_enabled: true
      logs_console_output: false
EOF
chown "$RUN_AS" "$III_CONFIG"

if [ ! -s "$HMAC_FILE" ]; then
  SECRET="$(openssl rand -hex 32)"
  umask 077
  printf '%s\n' "$SECRET" > "$HMAC_FILE"
  chmod 600 "$HMAC_FILE"
  chown "$RUN_AS" "$HMAC_FILE"
  echo "================================================================"
  echo "agentmemory: 首次启动已生成 HMAC 密钥"
  echo "AGENTMEMORY_SECRET=$SECRET"
  echo "现在复制这个值，之后不会再打印。"
  echo "存储位置: $HMAC_FILE (chmod 600)"
  echo "轮换方法: 删除卷上的 $HMAC_FILE 并重启容器。"
  echo "================================================================"
fi

AGENTMEMORY_SECRET="$(cat "$HMAC_FILE")"
export AGENTMEMORY_SECRET

exec gosu "$RUN_AS" agentmemory "$@"
