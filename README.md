# 农场助手·定制（分发包）

本仓库只放**已保护的编译产物**，不含任何源码。

## 发布标签规则

| 标签前缀 | 内容 |
|---|---|
| `bot-v*` | 服务端（Docker 镜像、预编译包、更新器） |
| `v*` | Android 客户端 APK |

两类发布互不干扰：服务端更新器只认 `bot-v*`，App 只认 `v*`。

## 下载

- 服务端：见 [Releases](../../releases)，取标签以 `bot-v` 开头的最新一条
  - `qq-farm-bot-protected-image.tar.gz` — Docker 镜像（推荐，离线可用）
  - `qq-farm-bot-protected-node20-x64.tar.gz` — 预编译包（内置 Node 20.19.6，start.sh 直跑）
  - `SHA256SUMS.txt` — 校验值
- 客户端：取标签以 `v` 开头的最新一条，下载 `farm-mobile-*-release.apk`

## 部署

见 [DEPLOY-RELEASE.md](DEPLOY-RELEASE.md)。

```bash
bash deploy/install-update.sh --repo Baochuya/farm-release
```

离线更新：把镜像包放到 `.update/image.tar.gz`，网页点“一键更新”。

## 授权

未导入授权时自动 30 天试用。授权文件 `license.json` 放到 `data/license.json` 后重启生效。
