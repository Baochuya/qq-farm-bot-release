#!/bin/bash
# qq-farm-bot 一键更新：宿主机安装脚本
#
# 用途：任何部署了本项目（docker compose）的实例，执行一次本脚本即可启用
#       网页端【设置 → 版本与更新 → 检测更新/一键更新】。
#
# 用法（在项目根目录执行）：
#   bash deploy/install-update.sh
#   bash deploy/install-update.sh --repo Baochuya/qq-farm-bot-release
#   bash deploy/install-update.sh --token ghp_xxx      # 私有仓库才需要
#   bash deploy/install-update.sh --no-cron            # 只准备目录，不装 cron
#
# 说明：
#   1) 容器无法自我重建镜像，所以由宿主机 cron 每分钟运行 deploy/update-runner.sh；
#      网页端只负责“写请求 + 展示进度”，交换目录为项目根 .update（挂载进容器 /app/core/data/update）。
#   2) 仓库为私有时，token 需要具备该仓库的读取权限（部署者自己的 PAT，或被加入仓库协作者）。
#   3) 重复执行是安全的（幂等）。

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
UPD="$ROOT/.update"
REPO_URL=""
BRANCH="main"
TOKEN=""
INSTALL_CRON=1
CRON_TAG="# qq-farm-bot-updater"

while [ $# -gt 0 ]; do
    case "$1" in
        --repo) REPO_URL="${2:-}"; shift 2 ;;
        --branch) BRANCH="${2:-main}"; shift 2 ;;
        --token) TOKEN="${2:-}"; shift 2 ;;
        --no-cron) INSTALL_CRON=0; shift ;;
        -h|--help) sed -n '2,20p' "${BASH_SOURCE[0]}"; exit 0 ;;
        *) echo "未知参数: $1"; exit 1 ;;
    esac
done

say() { printf '%s\n' "$*"; }
die() { printf '错误: %s\n' "$*" >&2; exit 1; }

say "== qq-farm-bot 一键更新安装 =="
say "项目目录: $ROOT"
say "交换目录: $UPD"

# ---- 依赖检查 ----
command -v docker >/dev/null 2>&1 || die "未找到 docker"
docker compose version >/dev/null 2>&1 || die "未找到 docker compose v2（docker compose version 失败）"
command -v python3 >/dev/null 2>&1 || die "未找到 python3（状态文件写入依赖它）"

if [ ! -f "$ROOT/docker-compose.yml" ] && [ ! -f "$ROOT/compose.yml" ]; then
    die "当前目录不像项目根目录（缺少 docker-compose.yml）"
fi

# docker 权限
if ! docker info >/dev/null 2>&1; then
    say "警告: 当前用户无法访问 docker，请用有 docker 权限的用户执行（或加入 docker 组）。"
fi

# ---- 目录与权限 ----
mkdir -p "$UPD/home/.docker"
chmod 700 "$UPD" 2>/dev/null || true
say "已准备 $UPD"

# ---- 更新源 ----
if [ -z "$REPO_URL" ] && [ -f "$UPD/config.json" ]; then
    REPO_URL="$(python3 - "$UPD/config.json" <<'PY' 2>/dev/null || true
import json, sys
try:
    d = json.load(open(sys.argv[1], encoding="utf-8"))
    o, r = d.get("owner", ""), d.get("repo", "")
    if o and r:
        print(f"{o}/{r}")
except Exception:
    pass
PY
)"
fi
if [ -z "$REPO_URL" ]; then
    die "未配置更新源。请用 --repo <owner>/<repo> 或 https://github.com/<owner>/<repo> 指定"
fi

OWNER=""
REPO=""
if [[ "$REPO_URL" =~ ^([A-Za-z0-9_.-]+)/([A-Za-z0-9_.-]+)$ ]]; then
    OWNER="${BASH_REMATCH[1]}"
    REPO="${BASH_REMATCH[2]}"
elif [[ "$REPO_URL" =~ github\.com[:/]([^/]+)/([^/.]+)(\.git)?/?$ ]]; then
    OWNER="${BASH_REMATCH[1]}"
    REPO="${BASH_REMATCH[2]}"
fi
[ -n "$OWNER" ] && [ -n "$REPO" ] || die "无法从仓库地址解析 owner/repo: $REPO_URL"
say "更新源: $OWNER/$REPO（产物镜像分发）"

# 分发版不依赖 git：直接从 GitHub Release 下载镜像产物，无需初始化本地仓库

# ---- 写配置 ----
CONFIG_PY='
import json, sys, os
path, owner, repo, branch = sys.argv[1:5]
data = {}
if os.path.exists(path):
    try:
        data = json.load(open(path, encoding="utf-8"))
    except Exception:
        data = {}
data.update({"owner": owner, "repo": repo, "branch": branch})
tmp = path + ".tmp"
json.dump(data, open(tmp, "w", encoding="utf-8"), ensure_ascii=False, indent=2)
os.replace(tmp, path)
'
python3 -c "$CONFIG_PY" "$UPD/config.json" "$OWNER" "$REPO" "$BRANCH" || die "写入 config.json 失败"
chmod 644 "$UPD/config.json" 2>/dev/null || true

if [ -n "$TOKEN" ]; then
    printf '%s' "$TOKEN" >"$UPD/auth"
    chmod 600 "$UPD/auth"
    say "已写入访问 token（$UPD/auth，权限 600）"
elif [ -f "$UPD/auth" ]; then
    say "已存在 token 文件，保持不变"
else
    say "未提供 token：公开仓库可正常更新（无需 token）"
fi

# ---- 执行器 ----
chmod +x "$ROOT/deploy/update-runner.sh" 2>/dev/null || true
[ -f "$ROOT/deploy/update-runner.sh" ] || die "缺少 deploy/update-runner.sh"

# 首次运行一次，写入心跳并创建日志（无请求时立即退出）
bash "$ROOT/deploy/update-runner.sh" || true
say "执行器自检完成，心跳文件: $UPD/runner.heartbeat"

# ---- cron ----
if [ "$INSTALL_CRON" = "1" ]; then
    if ! command -v crontab >/dev/null 2>&1; then
        say "警告: 未找到 crontab，请手动将下面一行加入定时任务（每分钟执行）:"
        say "  * * * * * bash $ROOT/deploy/update-runner.sh >/dev/null 2>&1"
    else
        CURRENT="$(crontab -l 2>/dev/null || true)"
        CLEANED="$(printf '%s\n' "$CURRENT" | grep -v 'deploy/update-runner.sh' | grep -v 'qq-farm-update/runner.sh' | grep -v "$CRON_TAG" | sed '/^$/d')"
        {
            [ -n "$CLEANED" ] && printf '%s\n' "$CLEANED"
            printf '* * * * * bash %s/deploy/update-runner.sh >>%s/.update/cron.log 2>&1 %s\n' "$ROOT" "$ROOT" "$CRON_TAG"
        } | crontab - || die "写入 crontab 失败"
        say "已安装 cron（每分钟巡检一次）"
    fi
fi

say ""
say "== 完成 =="
say "1. 若刚修改过 docker-compose.yml 的挂载，请执行: cd $ROOT && docker compose up -d"
say "2. 打开网页 → 设置 → 版本与更新 → 检测更新"
say "3. 分发仓为公开仓库时无需 token；若改为私有，请在【更新源设置】填写读权限 token"
say "4. 执行日志: $UPD/runner.log"
