# 分发部署说明（受保护产物版）

本仓库只提供**已保护的编译产物**，不提供源码。
源码仓库与分发仓库分离：源码仓私有，分发仓公开。

发布产物（每个 Release 附件）：

| 文件 | 用途 |
|---|---|
| `qq-farm-bot-protected-image.tar.gz` | Docker 镜像（推荐方式） |
| `qq-farm-bot-protected-image.tar.gz.sha256` | 镜像包校验值 |
| `qq-farm-bot-protected-node20-x64.tar.gz` | 预编译包，供 `start.sh` 方式运行 |
| `farm-mobile-x.y.z-release.apk` | Android 客户端 |

支持两种运行方式（**不再支持 `pnpm dev` 源码开发态**，该方式仅源码仓自用）：

- 方式 A：Docker Compose（推荐）
- 方式 B：`start.sh` 后台运行（需 Node.js 20.x，离线可用）

---

## 方式 A：Docker Compose

```bash
# 1. 准备目录
mkdir -p qq-farm-bot/data qq-farm-bot/.update
cd qq-farm-bot

# 2. 取运行时 compose（分发仓自带，无 build 段）
curl -fsSLO https://raw.githubusercontent.com/<owner>/<repo>/main/deploy/docker-compose.runtime.yml
mv docker-compose.runtime.yml docker-compose.yml

# 3. 载入镜像
docker load -i qq-farm-bot-protected-image.tar.gz

# 4. 启动
docker compose up -d

# 5. 打开 http://<主机IP>:3007 配置账号
```

数据全部落在 `./data`，升级不会丢。

## 方式 B：start.sh 后台运行

```bash
tar -xzf qq-farm-bot-protected-node20-x64.tar.gz
cd qq-farm-bot
node -v   # 必须是 v20.x，字节码与 Node 主版本绑定
bash start.sh     # 启动
bash stop.sh      # 停止
```

脚本会自动识别预编译包（存在 `core/bootstrap.js` 且无源码），跳过依赖安装与构建；Node 主版本不符会直接报错退出并提示改用 Docker，避免出现难懂的字节码报错。

---

## 在线更新（一键更新）

更新链路已改为**下载发布产物 + docker load**，不再需要 git 与源码。

宿主机执行一次：

```bash
bash deploy/install-update.sh --repo Baochuya/farm-release
```

- 写入 `.update/config.json`（owner/repo/proxy）并安装 cron，每分钟检查一次请求
- 网页端「设置 → 版本与更新 → 一键更新」写请求，宿主机执行 `deploy/update-runner.sh`
- 流程：取 latest Release → 下载镜像包 → 校验 sha256 → 备份旧镜像 → `docker load` → `compose up -d --force-recreate` → 健康检查
- 失败自动回滚到 `<镜像名>-rollback`

## 离线更新

无外网时，把镜像包放到 `.update/image.tar.gz`，然后在网页端点击「一键更新」。执行器会优先使用本地包，跳过下载。

---

## 授权（License）

未检测到授权文件时自动进入 **30 天试用期**，试用期结束后需导入授权才能启动。

**在你自己（授权方）机器上签发**，私钥只在本地保存：

```bash
cd core/protect

# 查看设备的 machineId（在部署方机器上执行，或看启动日志）
node license.mjs machine --data ./core/data

# 签发：绑定设备 + 有效期
node license.mjs issue --owner "客户名称" --expires 2027-12-31 \
  --machine <machineId> --note "某客户实例" --out license.json

# 校验
node license.mjs verify license.json --data ./core/data
```

把 `license.json` 放到部署方的 `data/license.json`（Docker 为 `./data/license.json`），重启生效。

- 授权采用 Ed25519 签名，部署方无法伪造（拿不到私钥）
- 换机器、改系统时间超过容差、篡改任一 `.jsc` 文件都会导致校验失败

---

## 保护强度说明（重要，请如实预期）

已实现：

- 源码不随产物下发；TS 编译为 V8 字节码（`.jsc`，与 Node 20 绑定）
- 代码混淆 + 去除 sourcemap
- 每个受保护文件的哈希写入 `manifest` 并做整体签名，启动时校验，改一个字节就拒绝启动
- 授权与设备绑定、有效期校验，签名私钥不下发
- App 端：R8 混淆、签名校验、更新包 sha256 校验

不能实现：

- **无法做到"绝对不可破解"**。运行在对方机器上的代码，对方拥有 root、可以 attach 容器、dump 内存、替换 Node 运行时。字节码可被专门工具还原为近似源码（成本较高但可行）。
- 因此本方案的目标是：**把破解成本抬到"不值得"**，而不是物理上不可能。

如果后续需要更高强度，唯一显著有效的路径是把核心业务逻辑放到你的服务器（客户端只做壳），代价是必须联网、离线不可用——与当前"离线可用"的要求冲突。
