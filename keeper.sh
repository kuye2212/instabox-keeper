#!/usr/bin/env bash
# keeper.sh — InstaBox 机器的保活 + 定时轮转
#
# 由 GitHub Actions 每 10 分钟调用一次（cron-job.org 也可以 dispatch 同一支 workflow）。
# 每次调用按顺序做三件事：
#
#   0. 续 activity lease —— 这步才是「保活」：只要租约还有效，平台就不会因为
#      「闲置 30 分钟」把机器挂起。以前没有这一步，所以机器每闲半小时就真挂一次，
#      全靠下一次 Actions 来捞（实测平均停机 8.8 分钟）。
#   1. 该轮转就轮转 —— 连续运行快到平台上限时，主动 suspend → resume 把计时清零。
#      上限从 API 的 maxRunMinutes 现取，绝不写死：免费额度并不统一，
#      2026-11 实测到 120 和 480 两种，同一账号也可能随时间调整。
#   2. 兜底拉起 —— 机器真的已经停了（冷却已过），start 拉回来。
#
# 状态记在 state.json（workflow 自动提交回仓库），因为 runner 每次都是全新环境。

set -uo pipefail

MACHINE_ID="${MACHINE_ID:?MACHINE_ID is required}"
API_BASE="${API_BASE:-https://api.instabox.sh}"

# 相对平台上限留多少余量再轮转（分钟）。平台的 cron 和我们的 cron 都不精确，
# 留够余量才能保证「我们转」而不是「平台掐」。
ROTATE_MARGIN_MIN="${ROTATE_MARGIN_MIN:-25}"
# 轮转后停多久（秒）。suspend 是暂停，进程还在；停 10 秒足够让平台记录一次新生命周期。
ROTATE_HOLD_SEC="${ROTATE_HOLD_SEC:-10}"
# 租约秒数：要明显大于调度间隔（10 分钟），才能扛住 GitHub cron 的延迟。
# 1800 秒 = 3 倍余量。
LEASE_TTL="${LEASE_TTL:-1800}"
LEASE_NAME="${LEASE_NAME:-keepalive}"

# 兼容旧参数：如果显式给了 RUN_MINUTES，就仍然按它走
LEGACY_RUN_MINUTES="${RUN_MINUTES:-}"

STATE_FILE="${STATE_FILE:-state.json}"
PY="${PY_BIN:-$(command -v python3 || command -v python || true)}"

[ -n "$PY" ] || { echo "::error::no python3/python on PATH"; exit 1; }
[ -n "${INSTABOX_API_KEY:-}" ] || { echo "::error::INSTABOX_API_KEY is empty — set the repo secret"; exit 1; }

API_CODE=000
API_BODY=""

# call METHOD PATH [BODY] —— 直接调用（不要用 $( ) 包住），结果写进 API_CODE / API_BODY
call() {
  local method="$1" path="$2" body="${3:-}"
  local resp
  local -a args=(-sS -X "$method"
                 -H "X-API-Key: ${INSTABOX_API_KEY}"
                 -H 'Accept: application/json'
                 -w '\n%{http_code}' --max-time 30)
  if [ "$method" = "PUT" ] || [ "$method" = "POST" ] || [ "$method" = "DELETE" ]; then
    # 换状态的接口缺 Idempotency-Key 会直接 400
    args+=(-H "Idempotency-Key: $("$PY" -c 'import uuid;print(uuid.uuid4())')")
  fi
  if [ -n "$body" ]; then
    args+=(-H 'Content-Type: application/json' -d "$body")
  elif [ "$method" = "POST" ]; then
    args+=(-H 'Content-Type: application/json' -d '{}')
  fi
  resp="$(curl "${args[@]}" "$API_BASE$path" 2>/dev/null)" || resp=$'\n000'
  API_CODE="${resp##*$'\n'}"
  API_BODY="${resp%$'\n'*}"
}

jget() {
  "$PY" -c '
import json,sys
try:
    d=json.loads(sys.stdin.read())
except Exception:
    raise SystemExit
v=d
for p in sys.argv[1].split("."):
    v = v.get(p) if isinstance(v,dict) else None
    if v is None: break
print("" if v is None else v)
' "$1"
}

jfirst() {
  local body="$1"; shift
  for k in "$@"; do
    local v; v="$(printf '%s' "$body" | jget "$k")"
    [ -n "$v" ] && { printf '%s' "$v"; return; }
  done
  printf ''
}

to_epoch() {
  [ -n "$1" ] || { printf ''; return; }
  date -u -d "$1" +%s 2>/dev/null || printf ''
}

save_state() {
  "$PY" - "$STATE_FILE" "$1" "$2" <<'PY'
import json,sys,time
path,key,val=sys.argv[1],sys.argv[2],sys.argv[3]
try:
    d=json.load(open(path))
except Exception:
    d={}
d[key]=int(val)
d["updatedAt"]=time.strftime("%Y-%m-%dT%H:%M:%SZ",time.gmtime())
json.dump(d,open(path,"w"),indent=2)
PY
}

read_state() {
  [ -f "$STATE_FILE" ] || { printf ''; return; }
  "$PY" - "$STATE_FILE" "$1" <<'PY' 2>/dev/null
import json,sys
try:
    d=json.load(open(sys.argv[1]))
    v=d.get(sys.argv[2])
    print("" if v is None else v)
except Exception:
    print("")
PY
}

now="$(date -u +%s)"
echo "now=$(date -u +%FT%TZ) lease_ttl=${LEASE_TTL}s margin=${ROTATE_MARGIN_MIN}m"

call GET "/v1/machines/$MACHINE_ID"
body="$API_BODY"
if [ "$API_CODE" != "200" ]; then
  echo "::error::GET machine failed http=$API_CODE body=$(printf '%s' "$body" | head -c 300)"
  exit 1
fi

state="$(printf '%s' "$body" | jget state | tr '[:upper:]' '[:lower:]')"
cooldown="$(jfirst "$body" cooldownUntil cooldown_until)"
max_run="$(jfirst "$body" maxRunMinutes max_run_minutes)"
started_raw="$(jfirst "$body" runStartedAt run_started_at startedAt started_at lastStartedAt)"

if [ -z "$state" ]; then
  echo "::error::cannot parse state; body=$(printf '%s' "$body" | head -c 300)"
  exit 1
fi

# ---------- 0. 续租（保活的核心） ----------
renew_lease() {
  call PUT "/v1/machines/$MACHINE_ID/activity-leases/$LEASE_NAME" "{\"ttlSeconds\":$LEASE_TTL}"
  if [ "$API_CODE" = "200" ] || [ "$API_CODE" = "201" ]; then
    echo "续租成功，到期 $(printf '%s' "$API_BODY" | jget expiresAt)"
    return 0
  fi
  echo "::warning::续租失败 http=$API_CODE body=$(printf '%s' "$API_BODY" | head -c 200)"
  return 1
}

# 冷却期内所有唤醒路径都会被拒，先别白打接口
cd_epoch="$(to_epoch "$cooldown")"
in_cooldown=0
if [ -n "$cd_epoch" ] && [ "$now" -lt "$cd_epoch" ]; then
  in_cooldown=1
  echo "冷却中，直到 $cooldown（还剩 $(( (cd_epoch-now)/60 )) 分钟）"
fi

if [ "$state" = "running" ]; then
  renew_lease
fi

case "$state" in
  running|active|started)
    ;;
  suspended|stopped|hibernated|paused|off)
    [ "$in_cooldown" = "1" ] && exit 0
    echo "机器处于 $state，冷却已过 → 拉起"
    call POST "/v1/machines/$MACHINE_ID/start"
    if [ "$API_CODE" = "200" ] || [ "$API_CODE" = "202" ]; then
      echo "start 已下发"
      save_state lastStart "$now"
      exit 0
    fi
    echo "::warning::start 失败 http=$API_CODE body=$(printf '%s' "$API_BODY" | head -c 300)"
    exit 0
    ;;
  starting|pending|provisioning|stopping|rebooting|restarting)
    echo "过渡态 $state，本轮跳过"
    exit 0
    ;;
  *)
    echo "未知状态 '$state'，本轮跳过"
    exit 0
    ;;
esac

# ---------- 1. 判断要不要轮转 ----------
anchor="$(to_epoch "$started_raw")"
[ -n "$anchor" ] || anchor="$(read_state lastStart)"
if [ -z "$anchor" ] || ! [ "$anchor" -gt 0 ] 2>/dev/null; then
  echo "没有可信的启动时间，以现在重新计时"
  save_state lastStart "$now"
  exit 0
fi

age_min="$("$PY" -c "print(int(($now-$anchor)/60))")"
echo "已连续运行 ${age_min} 分钟（锚点 $anchor）"

# 轮转阈值：一律以 API 的 maxRunMinutes 为准；RUN_MINUTES 只能让它更早，不能更晚。
# 免费号的 maxRunMinutes 并不统一：实测同一账号下可能随时间调整，不同账号也不同
# （2026-11 观测到 120 和 480 两种）。所以这里绝不写死，一律现取。
# 老 workflow 里写着的 RUN_MINUTES=470 会被夹在安全点之内，不会把机器跑到被平台强制挂起。
platform_threshold=""
if [ -n "$max_run" ] && [ "$max_run" -gt 0 ] 2>/dev/null; then
  platform_threshold="$((max_run - ROTATE_MARGIN_MIN))"
  [ "$platform_threshold" -gt 5 ] || platform_threshold=5
  echo "平台上限 ${max_run} 分钟，留 ${ROTATE_MARGIN_MIN} 分钟余量 → 安全点 ${platform_threshold} 分钟"
else
  # 拿不到上限时按当前已知的最大免费额度（480）保守处理，宁可早转也不撞硬限制
  platform_threshold=$((480 - ROTATE_MARGIN_MIN))
  [ "$platform_threshold" -gt 5 ] || platform_threshold=455
  echo "::warning::没拿到 maxRunMinutes，按免费额度 480 分钟估算，安全点 ${platform_threshold} 分钟"
fi

threshold="$platform_threshold"
if [ -n "$LEGACY_RUN_MINUTES" ]; then
  if [ "$LEGACY_RUN_MINUTES" -lt "$platform_threshold" ] 2>/dev/null; then
    threshold="$LEGACY_RUN_MINUTES"
    echo "RUN_MINUTES=${LEGACY_RUN_MINUTES} 比安全点更早，采用它"
  elif [ "$LEGACY_RUN_MINUTES" -gt "$platform_threshold" ] 2>/dev/null; then
    echo "::warning::RUN_MINUTES=${LEGACY_RUN_MINUTES} 超过平台安全点，忽略，改用 ${platform_threshold}"
  fi
fi
echo "本轮轮转阈值 ${threshold} 分钟（已连续运行 ${age_min} 分钟）"

if [ "$age_min" -lt "$threshold" ]; then
  echo "还没到 ${threshold} 分钟，继续跑"
  exit 0
fi

# ---------- 2. 轮转：suspend → 稍等 → resume ----------
# 用 suspend 而不是 stop：suspend 是暂停，进程还在；stop 会杀掉 astrbot/QQ 等所有服务。
echo "已达 ${threshold} 分钟 → suspend（暂停，不杀进程）"
call POST "/v1/machines/$MACHINE_ID/suspend"
echo "suspend http=$API_CODE"

settled=""
for _ in $(seq 1 30); do
  call GET "/v1/machines/$MACHINE_ID"
  s="$(printf '%s' "$API_BODY" | jget state | tr '[:upper:]' '[:lower:]')"
  case "$s" in
    suspended|stopped|hibernated|paused|off) settled="$s"; break ;;
  esac
  sleep 5
done

if [ -z "$settled" ]; then
  echo "::warning::suspend 后仍未落地（state=${s:-?}），下一轮重试"
  exit 0
fi
echo "已暂停（$settled），保持 ${ROTATE_HOLD_SEC} 秒"
sleep "$ROTATE_HOLD_SEC"

echo "恢复 → resume"
call POST "/v1/machines/$MACHINE_ID/resume"
if [ "$API_CODE" != "200" ] && [ "$API_CODE" != "202" ]; then
  echo "resume 被拒 http=$API_CODE，改用 start"
  call POST "/v1/machines/$MACHINE_ID/start"
fi

if [ "$API_CODE" = "200" ] || [ "$API_CODE" = "202" ]; then
  save_state lastStart "$now"
  echo "已重新启动，运行计时清零，下次轮转在 ${threshold} 分钟后"
  # 刚恢复就续一次租，避免恢复瞬间被判空闲
  renew_lease
else
  echo "::error::恢复失败 http=$API_CODE body=$(printf '%s' "$API_BODY" | head -c 300)"
  exit 1
fi
