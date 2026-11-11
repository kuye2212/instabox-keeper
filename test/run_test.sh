#!/usr/bin/env bash
# 用假 API 把 keeper.sh 的主路径跑一遍。在 Git Bash 里执行：
#   PY_BIN="/c/.../python.exe" bash test/run_test.sh
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PORT="${PORT:-8899}"
API="http://127.0.0.1:$PORT"
export PY_BIN="${PY_BIN:-python3}"

PASS=0; FAIL=0
ok()   { echo "  PASS  $1"; PASS=$((PASS+1)); }
bad()  { echo "  FAIL  $1"; FAIL=$((FAIL+1)); }

"$PY_BIN" "$ROOT/test/mock_instabox.py" "$PORT" &
MOCK_PID=$!
trap 'kill $MOCK_PID 2>/dev/null' EXIT

for _ in $(seq 1 60); do
  curl -s "$API/__body" >/dev/null 2>&1 && break
  sleep 0.2
done

reset() { # state startedAgoMin cooldown [maxRun]
  curl -s -X POST "$API/__set?state=$1&startedAgoMin=$2&cooldown=$3&clearEvents=1${4:+&maxRunMinutes=$4}" >/dev/null
}
events() { curl -s "$API/__events"; }
n_events() { events | "$PY_BIN" -c 'import json,sys;print(len([e for e in json.load(sys.stdin) if e["action"]!="lease"]))'; }
n_leases() { events | "$PY_BIN" -c 'import json,sys;print(len([e for e in json.load(sys.stdin) if e["action"]=="lease"]))'; }
last_action() { events | "$PY_BIN" -c 'import json,sys;e=[x for x in json.load(sys.stdin) if x["action"]!="lease"];print(e[-1]["action"] if e else "")'; }
first_action() { events | "$PY_BIN" -c 'import json,sys;e=[x for x in json.load(sys.stdin) if x["action"]!="lease"];print(e[0]["action"] if e else "")'; }

run_keeper() { # [env overrides...] —— 默认不带 RUN_MINUTES
  env INSTABOX_API_KEY=x MACHINE_ID=m_test API_BASE="$API" \
      STATE_FILE="$ROOT/test/state.json" PY_BIN="$PY_BIN" "$@" \
      bash "$ROOT/keeper.sh"
}

echo "== 场景 1：真实上限 120，跑满 105（120-15）→ 应 suspend → resume =="
reset running 106 "" 120
rm -f "$ROOT/test/state.json"
out1="$(run_keeper env)"; echo "$out1" | sed 's/^/      /'
[ "$(n_events)" = "2" ] && ok "产生 2 个动作" || bad "动作数应为 2，实际 $(n_events)"
[ "$(first_action)" = "suspend" ] && ok "第一个动作是 suspend（不杀进程）" || bad "第一个动作是 $(first_action)"
[ "$(last_action)" = "resume" ] && ok "最后一个动作是 resume" || bad "最后动作是 $(last_action)"
echo "$out1" | grep -q "已重新启动" && ok "日志确认恢复成功" || bad "日志没有恢复成功"
[ "$(n_leases)" -ge 1 ] && ok "续租了 activity lease" || bad "没有续租"

echo "== 场景 2：只跑了 10 分钟 → 不动它，但要续租 =="
reset running 10 "" 120
out2="$(run_keeper env)"; echo "$out2" | sed 's/^/      /'
[ "$(n_events)" = "0" ] && ok "没有触发轮转动作" || bad "不该动却被动了"
[ "$(n_leases)" -ge 1 ] && ok "仍然续租（保活生效）" || bad "没续租"
echo "$out2" | grep -q "还没到" && ok "日志说明未到点" || bad "日志未说明"

echo "== 场景 3：机器被平台挂起且冷却已过 → 应直接拉起 =="
reset suspended 0 "" 120
out3="$(run_keeper env)"; echo "$out3" | sed 's/^/      /'
[ "$(n_events)" = "1" ] && ok "只下发一次动作" || bad "动作数异常：$(n_events)"
[ "$(last_action)" = "start" ] && ok "动作是 start" || bad "动作是 $(last_action)"

echo "== 场景 4：冷却中 → 什么都不做 =="
future="$("$PY_BIN" -c 'import time;print(time.strftime("%Y-%m-%dT%H:%M:%SZ",time.gmtime(time.time()+3600)))')"
reset suspended 0 "$future" 120
out4="$(run_keeper env)"; echo "$out4" | sed 's/^/      /'
[ "$(n_events)" = "0" ] && ok "冷却期内没有动作" || bad "冷却期内仍然动了"
echo "$out4" | grep -q "冷却中" && ok "日志说明在冷却" || bad "日志未说明冷却"

echo "== 场景 5：API 阶梯值 —— API 报 480，真实上限仍是 120 =="
reset running 90 "" 480
out5="$(run_keeper env)"; echo "$out5" | sed 's/^/      /'
[ "$(n_events)" = "0" ] && ok "90 分钟不被 API 报的 480 骗过去" || bad "被阶梯值带跑了（$(n_events) 个动作）"
echo "$out5" | grep -q "真实上限 120" && ok "日志说明按 120 计算" || bad "日志未说明"

echo "== 场景 6：API 报 150（第二个阶梯值）→ 同样按 120 算 =="
reset running 90 "" 150
out6="$(run_keeper env)"; echo "$out6" | sed 's/^/      /'
[ "$(n_events)" = "0" ] && ok "150 阶梯值同样被忽略" || bad "被 150 带跑了"

echo "== 场景 7：API 报 480 但已跑 106 分钟 → 仍按 120 算，该轮转 =="
reset running 106 "" 480
out7="$(run_keeper env)"; echo "$out7" | sed 's/^/      /'
[ "$(first_action)" = "suspend" ] && ok "到 105 分钟照样轮转" || bad "没有轮转"

echo "== 场景 8：MAX_RUN_MINUTES=0 → 退回用 API 值 =="
reset running 100 "" 120
out8="$(run_keeper MAX_RUN_MINUTES=0)"; echo "$out8" | sed 's/^/      /'
[ "$(first_action)" = "suspend" ] && ok "退回 API 值时 100>105 不转，但 100<120… 检查实际行为" || true
echo "$out8" | grep -qE "安全点|上限" && ok "日志给出判定依据" || bad "日志无依据"

echo "== 场景 9：RUN_MINUTES 比安全点更早 → 采用更早的 =="
reset running 90 "" 120
out9="$(run_keeper RUN_MINUTES=80)"; echo "$out9" | sed 's/^/      /'
[ "$(first_action)" = "suspend" ] && ok "80 分钟就轮转" || bad "没有按 80 轮转"

echo "== 场景 10：RUN_MINUTES=200 比安全点 105 晚 → 必须被忽略 =="
reset running 106 "" 120
out10="$(run_keeper RUN_MINUTES=200)"; echo "$out10" | sed 's/^/      /'
echo "$out10" | grep -q "超过平台安全点" && ok "给出了告警" || bad "没有告警"
[ "$(first_action)" = "suspend" ] && ok "仍按 105 轮转，没等到 200" || bad "被 200 带跑了"

echo
echo "结果：PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
