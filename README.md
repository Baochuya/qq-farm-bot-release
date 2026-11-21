# QQ农场助手·定制（分发）

本仓库只提供**已保护的编译产物**，不包含任何源码。

## 下载

在 [Releases](../../releases/latest) 页面下载：

| 文件 | 说明 |
|---|---|
| `qq-farm-bot-protected-image.tar.gz` | Docker 镜像（推荐） |
| `qq-farm-bot-protected-image.tar.gz.sha256` | 校验值 |
| `qq-farm-bot-protected-node20-x64.tar.gz` | 预编译包（Node 20.x 直跑） |
| `farm-mobile-*.apk` | Android 客户端 |

## 部署

见 [DEPLOY-RELEASE.md](DEPLOY-RELEASE.md)。

- 方式 A：Docker Compose（推荐，离线可用）
- 方式 B：start.sh（需 Node.js 20.x，离线可用）
- 在线一键更新：`bash deploy/install-update.sh --repo Baochuya/qq-farm-bot-release`
- 离线更新：把镜像包放到 `.update/image.tar.gz`，网页点“一键更新”

## 授权

未导入授权时自动 30 天试用。授权文件为 `license.json`，放到 `data/license.json` 后重启生效。
