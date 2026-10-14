# agentmemory 远程部署镜像
# 基于官方 deploy/coolify 模板改造：node:22-slim + iii 引擎 0.22.1 + agentmemory worker
# 引擎与 SDK 版本必须严格一致（wire protocol 兼容要求）

ARG III_VERSION=0.22.1

FROM iiidev/iii:${III_VERSION} AS iii-image

FROM node:22-slim

ARG AGENTMEMORY_VERSION=0.9.30
ARG III_VERSION=0.22.1
ARG III_SDK_VERSION=0.22.1

# tini: init 进程保证信号正确传递; gosu: 降权到 node 用户; openssl: 首次启动生成 HMAC 密钥
RUN apt-get update \
 && apt-get install -y --no-install-recommends openssl ca-certificates tini gosu \
 && rm -rf /var/lib/apt/lists/*

# 从官方 iii 镜像复制钉死版本的引擎二进制，并校验版本
COPY --from=iii-image /app/iii /usr/local/bin/iii
RUN iii --version 2>&1 | grep -qF "${III_VERSION}" \
 || { echo "the iiidev/iii:${III_VERSION} image does not contain iii ${III_VERSION}" >&2; exit 1; }

WORKDIR /opt/agentmemory
RUN [ "${III_VERSION}" = "${III_SDK_VERSION}" ] \
 || { echo "III_VERSION=${III_VERSION} and III_SDK_VERSION=${III_SDK_VERSION} must be the same release" >&2; exit 1; }
RUN printf '{"name":"agentmemory-remote","version":"1.0.0","private":true,"overrides":{"iii-sdk":"%s"}}\n' "${III_SDK_VERSION}" > package.json \
 && npm install "@agentmemory/agentmemory@${AGENTMEMORY_VERSION}" --omit=optional --no-fund --no-audit \
 && ln -s /opt/agentmemory/node_modules/.bin/agentmemory /usr/local/bin/agentmemory

ENV AGENTMEMORY_III_VERSION=${III_VERSION} \
    TINI_SUBREAPER=1 \
    MALLOC_ARENA_MAX=2

COPY --chmod=0755 entrypoint.sh /usr/local/bin/agentmemory-entrypoint.sh

# 仅暴露 REST 端口；3112/3113/49134 保持在容器内部
EXPOSE 3111

# 健康检查：node:22-slim 无 wget/curl，用 node 内置 http 探测
HEALTHCHECK --interval=30s --timeout=5s --start-period=60s --retries=3 \
  CMD node -e "require('http').get('http://127.0.0.1:3111/agentmemory/livez',r=>process.exit(r.statusCode===200?0:1)).on('error',()=>process.exit(1))"

ENTRYPOINT ["/usr/bin/tini", "--", "/usr/local/bin/agentmemory-entrypoint.sh"]
