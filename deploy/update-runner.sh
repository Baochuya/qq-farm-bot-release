#!/bin/bash
# qq-farm-bot 一键更新执行器（镜像分发版）
#
# 与旧版（git 拉源码 + 本机构建）的区别：
#   旧版：git fetch/reset -> docker compose build -> up -d
#   新版：下载发布产物镜像 tar -> 校验 sha256 -> docker load -> up -d
#   —— 因为分发仓库不包含源码，只提供已保护的镜像产物。
#
# 触发：用户级 cron 每分钟执行一次；只处理 $UPD/request.json 存在的情况。
# 过程与结果写入 $UPD/state.json（管理端 /api/system/update/status 读取）。
#
# 离线部署：把镜像 tar 放到 $UPD/image.tar.gz，再在网页端点“一键更新”，
#          脚本会跳过下载直接使用本地文件。
#
# 配置（$UPD/config.json）：
#   owner / repo   GitHub 分发仓库，如 Baochuya/qq-farm-bot-release
#   asset          资产名，默认 qq-farm-bot-protected-image.tar.gz
#   proxy          HTTP 代理，如 http://127.0.0.1:7890（可选）
#   $UPD/auth      存放 GitHub token（仅私有仓库需要）
#
# 失败自动回滚到上一镜像（<image>-rollback）。

set -uo pipefail

export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"

SCRIPT_PATH="$(readlink -f "${BASH_SOURCE[0]}")"
SCRIPT_DIR="$(dirname "$SCRIPT_PATH")"
ROOT="${UPDATE_ROOT:-$(cd "$SCRIPT_DIR/.." && pwd)}"
UPD="${UPDATE_DIR:-$ROOT/.update}"

export HOME="${UPDATE_HOME:-$UPD/home}"
export DOCKER_CONFIG="$HOME/.docker"
mkdir -p "$DOCKER_CONFIG" "$UPD"

REQ="$UPD/request.json"
PROC="$UPD/request.processing.json"
ST="$UPD/state.json"
CFG="$UPD/config.json"
AUTH="$UPD/auth"
LOCK="$UPD/runner.lock"
LOG="$UPD/runner.log"
BEAT="$UPD/runner.heartbeat"
TOKEN=""
OWNER=""
REPO=""
PROXY=""
ASSET="qq-farm-bot-protected-image.tar.gz"
IMAGE=""
ROLLBACK=""
DRY_RUN="${UPDATE_DRY_RUN:-0}"

log() { printf '[%s] %s\n' "$(date '+%F %T')" "$*" >>"$LOG"; }

heartbeat() {
    date '+%Y-%m-%dT%H:%M:%S%:z' >"$BEAT" 2>/dev/null || true
}
trap heartbeat EXIT

exec 9>"$LOCK"
flock -n 9 || exit 0

if [ -f "$LOG" ] && [ "$(stat -c%s "$LOG" 2>/dev/null || echo 0)" -gt 2097152 ]; then
    tail -n 2000 "$LOG" >"$LOG.tmp" && mv "$LOG.tmp" "$LOG"
fi

read_cfg() {
    python3 - "$CFG" "$1" <<'PY' 2>/dev/null || true
import json, sys
path, key = sys.argv[1], sys.argv[2]
try:
    with open(path, encoding='utf-8') as f:
        data = json.load(f)
    val = data.get(key, '')
    if isinstance(val, (str, int)):
        print(str(val).strip())
except Exception:
    pass
PY
}

if [ -f "$CFG" ]; then
    OWNER="$(read_cfg owner)"
    REPO="$(read_cfg repo)"
    PROXY="$(read_cfg proxy)"
    _asset="$(read_cfg asset)"
    [ -n "$_asset" ] && ASSET="$_asset"
fi
[ -f "$AUTH" ] && TOKEN="$(tr -d '\r\n' <"$AUTH")"

# write_state <status> <step> <message> <fromSha> <toSha>
write_state() {
    python3 - "$ST" "$LOG" "$1" "$2" "$3" "${4:-}" "${5:-}" <<'PY'
import json, sys, os, datetime
st_path, log_path, status, step, msg, from_sha, to_sha = sys.argv[1:8]
prev = {}
try:
    with open(st_path, encoding='utf-8') as f:
        prev = json.load(f)
except Exception:
    prev = {}
log_tail = []
try:
    with open(log_path, encoding='utf-8', errors='replace') as f:
        log_tail = [line.rstrip('\n') for line in f.readlines()[-40:]]
except Exception:
    pass
now = datetime.datetime.now().astimezone().isoformat(timespec='seconds')
data = {
    'status': status,
    'step': step,
    'message': msg,
    'fromSha': (from_sha or prev.get('fromSha') or ''),
    'toSha': (to_sha or prev.get('toSha') or ''),
    'startedAt': prev.get('startedAt') or now,
    'updatedAt': now,
    'finishedAt': now if status in ('success', 'failed') else '',
    'log': log_tail,
}
if status == 'queued':
    data['startedAt'] = now
tmp = st_path + '.tmp'
with open(tmp, 'w', encoding='utf-8') as f:
    json.dump(data, f, ensure_ascii=False, indent=2)
os.replace(tmp, st_path)
PY
}

state_status() {
    python3 -c "import json,sys;print(json.load(open(sys.argv[1],encoding='utf-8')).get('status',''))" "$ST" 2>/dev/null || echo ""
}

resolve_image() {
    local f="$ROOT/docker-compose.yml"
    [ -f "$f" ] || f="$ROOT/compose.yml"
    [ -f "$f" ] || return 0
    awk '/^[[:space:]]*image:[[:space:]]*/{sub(/^[[:space:]]*image:[[:space:]]*/,""); print; exit}' "$f" | tr -d '"' | tr -d "'"
}

compose() {
    if docker compose version >/dev/null 2>&1; then
        (cd "$ROOT" && docker compose "$@")
    else
        (cd "$ROOT" && docker-compose "$@")
    fi
}

container_health() {
    local cid
    cid="$(compose ps -q 2>/dev/null | head -1)"
    [ -n "$cid" ] || { echo missing; return; }
    docker inspect --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}{{.State.Status}}{{end}}' "$cid" 2>/dev/null || echo missing
}

wait_healthy() {
    local i h
    for i in $(seq 1 60); do
        h="$(container_health)"
        case "$h" in
            healthy|running) return 0 ;;
            unhealthy|exited|dead) return 1 ;;
        esac
        sleep 3
    done
    return 1
}

fail_and_rollback() {
    local msg="$1"
    log "FAILED: $msg"
    write_state failed failed "$msg" "" ""
    if [ -n "$ROLLBACK" ] && [ -n "$IMAGE" ] && docker image inspect "$ROLLBACK" >/dev/null 2>&1; then
        log "回滚镜像 $ROLLBACK -> $IMAGE"
        docker tag "$ROLLBACK" "$IMAGE" >>"$LOG" 2>&1
        if [ "$DRY_RUN" != "1" ]; then
            compose up -d --force-recreate >>"$LOG" 2>&1
            wait_healthy || log "回滚后健康检查仍未通过"
        fi
        write_state failed failed "$msg（已回滚到上一镜像）" "" ""
    fi
    rm -f "$PROC"
    exit 1
}

# 无请求：检查是否有卡死的 running 状态
if [ ! -f "$REQ" ]; then
    if [ "$(state_status)" = "running" ]; then
        if [ -n "$(find "$ST" -mmin +20 2>/dev/null)" ]; then
            write_state failed failed "执行超时（超过 20 分钟无进展）" "" ""
        fi
    fi
    exit 0
fi

mv -f "$REQ" "$PROC" 2>/dev/null || exit 0

IMAGE="$(resolve_image)"
[ -n "$IMAGE" ] || IMAGE="qq-farm-bot:latest"
log "==== 开始更新，目标镜像 $IMAGE，资产 $ASSET ===="

DL_DIR="$UPD/dl"
mkdir -p "$DL_DIR"
TAR="$DL_DIR/$ASSET"

CURL_PREFIX=()
if [ -n "$PROXY" ]; then
    CURL_PREFIX=(-x "$PROXY")
    export http_proxy="$PROXY" https_proxy="$PROXY"
fi

# ---------- 1. 取发布信息 ----------
write_state running check "读取发布信息" "" ""
API="https://api.github.com/repos/$OWNER/$REPO/releases/latest"
META=""
if [ -n "$OWNER" ] && [ -n "$REPO" ]; then
    AUTH_HDR=()
    [ -n "$TOKEN" ] && AUTH_HDR=(-H "Authorization: token $TOKEN")
    META="$(curl -sSL --max-time 30 "${CURL_PREFIX[@]}" "${AUTH_HDR[@]}" \
        -H "Accept: application/vnd.github+json" "$API" 2>>"$LOG")" || true
fi

TAG=""
TAR_URL=""
SUM_URL=""
if [ -n "$META" ]; then
    read -r TAG TAR_URL SUM_URL <<<"$(printf '%s' "$META" | python3 -c '
import json, sys
try:
    d = json.load(sys.stdin)
except Exception:
    print(""); raise SystemExit
tag = d.get("tag_name") or ""
tar_url = sum_url = ""
asset = sys.argv[1]
for a in d.get("assets") or []:
    name = a.get("name") or ""
    if name == asset:
        tar_url = a.get("browser_download_url") or ""
    elif name in (asset + ".sha256", asset + ".sha256.txt"):
        sum_url = a.get("browser_download_url") or ""
print(tag, tar_url, sum_url)
' "$ASSET" 2>/dev/null)"
fi

# ---------- 2. 准备镜像包（本地离线包优先） ----------
write_state running download "准备镜像包" "" "${TAG:-}"
LOCAL_TAR="$UPD/image.tar.gz"
if [ -f "$LOCAL_TAR" ]; then
    log "使用本地离线镜像包 $LOCAL_TAR"
    TAR="$LOCAL_TAR"
    SUM_URL=""
elif [ -n "$TAR_URL" ]; then
    log "下载 $TAR_URL -> $TAR"
    curl -fSL --retry 3 --retry-delay 5 --max-time 1800 "${CURL_PREFIX[@]}" \
        -o "$TAR.part" "$TAR_URL" >>"$LOG" 2>&1 || fail_and_rollback "镜像包下载失败（网络或仓库权限问题）"
    mv -f "$TAR.part" "$TAR"
else
    fail_and_rollback "未找到可用的镜像包：请检查 .update/config.json 的 owner/repo，或把镜像 tar 放到 .update/image.tar.gz"
fi

# ---------- 3. 校验 ----------
write_state running verify "校验镜像包" "" "${TAG:-}"
if [ -n "$SUM_URL" ]; then
    EXPECT="$(curl -fsSL --max-time 60 "${CURL_PREFIX[@]}" "$SUM_URL" 2>>"$LOG" | awk '{print $1}' | head -1)"
else
    EXPECT=""
fi
if [ -n "$EXPECT" ]; then
    ACTUAL="$(sha256sum "$TAR" | awk '{print $1}')"
    if [ "$EXPECT" != "$ACTUAL" ]; then
        log "sha256 不匹配 expect=$EXPECT actual=$ACTUAL"
        rm -f "$TAR"
        fail_and_rollback "镜像包校验失败（sha256 不匹配）"
    fi
    log "sha256 校验通过 $ACTUAL"
else
    log "未提供 sha256，跳过校验"
fi

# ---------- 4. 备份当前镜像 ----------
if docker image inspect "$IMAGE" >/dev/null 2>&1; then
    ROLLBACK="$IMAGE-rollback"
    docker tag "$IMAGE" "$ROLLBACK" >>"$LOG" 2>&1 && log "已备份当前镜像为 $ROLLBACK"
fi

# ---------- 5. 载入镜像 ----------
write_state running load "载入新镜像" "" "${TAG:-}"
if [ "$DRY_RUN" = "1" ]; then
    log "DRY_RUN：跳过 docker load / compose up"
    write_state success done "试运行完成（未实际切换）" "" "${TAG:-}"
    rm -f "$PROC"
    exit 0
fi

if ! LOAD_OUT="$(docker load -i "$TAR" 2>&1)"; then
    echo "$LOAD_OUT" >>"$LOG"
    fail_and_rollback "docker load 失败：$(printf '%s' "$LOAD_OUT" | tail -n 3 | tr '\n' ' ')"
fi
echo "$LOAD_OUT" >>"$LOG"

LOADED_TAG="$(printf '%s' "$LOAD_OUT" | sed -n 's/^Loaded image: //p' | tail -1)"
if [ -n "$LOADED_TAG" ] && [ "$LOADED_TAG" != "$IMAGE" ]; then
    docker tag "$LOADED_TAG" "$IMAGE" >>"$LOG" 2>&1
fi
docker image inspect "$IMAGE" >/dev/null 2>&1 || fail_and_rollback "载入后镜像 $IMAGE 不存在"

# ---------- 6. 重启 ----------
write_state running restart "重启服务" "" "${TAG:-}"
compose up -d --force-recreate >>"$LOG" 2>&1 || fail_and_rollback "docker compose up 失败"

# ---------- 7. 健康检查 ----------
write_state running health "等待健康检查" "" "${TAG:-}"
if wait_healthy; then
    log "更新成功 ${TAG:-}"
    # 记录已安装版本，供网页端“检测更新”比对 Release tag
    if [ -n "$TAG" ]; then printf '%s\n' "$TAG" > "$UPD/installed-tag"; fi
    write_state success done "更新成功${TAG:+，版本 $TAG}" "" "${TAG:-}"
    rm -f "$PROC"
    exit 0
fi

fail_and_rollback "更新后健康检查未通过"
