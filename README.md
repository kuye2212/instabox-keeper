# instabox-keeper

用 GitHub Actions 给 InstaBox 机器做**保活 + 定时轮转**。

跑在 GitHub 的服务器上，所以：不需要你的电脑开机，不需要公网入口，也不需要那台云主机自己活着。
runner 只做一件事——出站访问 `api.instabox.sh`。

## 它解决什么

免费号有两个限制，它们叠加起来会让机器频繁掉线：

| 限制 | 后果 |
|---|---|
| 闲置 **30 分钟**自动挂起（`autoSuspendAfterSeconds=1800`） | 机器一闲就停，全靠下一次 Actions 来捞 |
| 连续运行上限（`maxRunMinutes`，实测 **120 分钟**） | 撞上后被平台强制挂起，冷却 **60–135 分钟**，谁也唤醒不了 |

实测（bo1，2026-11-04 ~ 11-10，用 guest agent 每分钟心跳量出来的）：

- 97 次挂起，**全部触发原因是 `idle`**，没有一次是 `maxRun`
- 单次停机中位 **8.8 分钟**，累计每天约 **2.4 小时**
- 挂起前连续活跃时段中位 **44 分钟**，正是「闲 30 分钟 → 挂起」

所以本脚本做两件事：

1. **续 activity lease** —— 每轮跑都续一次（默认 1800 秒），平台就不会因闲置挂起。
   这是真正的「保活」，不是事后抢救。
2. **到点轮转** —— 连续运行接近平台上限时，主动 `suspend → resume` 把计时清零，
   抢在平台强制挂起之前。阈值从 API 的 `maxRunMinutes` 现取，留 25 分钟余量。

## 每次被叫醒做什么

| 机器状态 | 动作 |
|---|---|
| `running` | 续租；连续运行接近上限就轮转，否则什么都不做 |
| `suspended` / `stopped` 且冷却已过 | 直接拉起 |
| 冷却中 | 等待，不做无用请求 |

连续运行时间优先取 API 返回的 `runStartedAt`，取不到才退回仓库里的 `state.json`。

## 部署

### 1. 建仓库

**建议用 public 仓库**，原因见下面「费用」。把本目录整个推上去即可：

```bash
cd instabox-keeper
git init -b main
git add -A
git commit -m "init"
gh repo create instabox-keeper --public --source=. --push
```

### 2. 加两个配置

```bash
# 必填：InstaBox 后台的 API key（只需要 machines:write）
gh secret set INSTABOX_API_KEY

# 可选：机器 ID（不设就用 workflow 里的默认值）
gh variable set INSTABOX_MACHINE_ID
```

### 3. 手动跑一次验证

```bash
gh workflow run instabox-keeper.yml
gh run watch
```

日志里应该出现：

```
续租成功，到期 ...
已连续运行 N 分钟（锚点 ...）
平台上限 120 分钟，留 25 分钟余量 → 安全点 95 分钟
还没到 95 分钟，继续跑
```

## 可调参数

都在 workflow 的 `env:` 里：

| 变量 | 默认 | 说明 |
|---|---|---|
| `ROTATE_MARGIN_MIN` | `25` | 距平台上限还有多少分钟就轮转 |
| `LEASE_TTL` | `1800` | 租约秒数，要明显大于 10 分钟的调度间隔 |
| `LEASE_NAME` | `keepalive` | 租约名 |
| `ROTATE_HOLD_SEC` | `10` | 轮转时暂停多久再恢复 |

**`RUN_MINUTES` 已被废弃。** 老版本写死 470 分钟，但平台实际上限是 120——
那个值永远不会触发，等于没有轮转。现在如果你还传 `RUN_MINUTES`：

- 比安全点**更早** → 采用它（允许你更保守）
- 比安全点**更晚** → 忽略并告警（防止把机器跑到被平台强制挂起）

## 费用

GitHub Actions 对 **public 仓库不限分钟数**，对 private 仓库每月 2000 分钟（免费额度）。

这个 workflow 每 10 分钟跑一次 = 每天 144 次。按每次最少 1 分钟计费：

| 仓库类型 | 每天 | 每月 | 结论 |
|---|---|---|---|
| public | 144 分钟（不计量） | 0 | 随便用 |
| private | 144 分钟 | ≈4300 分钟 | **超免费额度** |

要用 private 仓库的话，把 cron 从 `*/10` 改成 `*/30`（降 3 倍到 ≈1440 分钟/月）。

## 必须知道的几个坑

**GitHub 的 cron 不准。** 高峰期会延迟几分钟到十几分钟，最小粒度 5 分钟。
`LEASE_TTL=1800` 就是留给这个抖动的（3 倍余量）。

**轮转是物理暂停。** `suspend → resume` 期间机器上的服务会停十几秒。
用 `suspend` 而不是 `stop`：`suspend` 是暂停，进程还在；`stop` 会杀掉所有服务。

**不要只依赖这一个保活。** 如果机器上跑着重要服务，建议在另一台机器上
直接调 activity lease API 做内网保活（延迟几百毫秒，不经过第三方），
这个 GitHub workflow 作为兜底。

**长时间没有活动，定时任务会被停用。** GitHub 在仓库 60 天无提交后会暂停 scheduled
workflow。这个设计里 `state.json` 会被自动提交，正好能续命；但如果你长期没到点触发、
一次都没提交过，记得回来点一下 `gh workflow run` 或随便提交个东西。

## 本地测试

不联网、不用真 API key，用假 API 跑完整流程：

```bash
# 需要 bash（Git Bash 即可）、curl 和 python3
PY_BIN=$(command -v python3) bash test/run_test.sh
```

覆盖 6 个场景：到点轮转、未到点不动、平台停掉后拉起、冷却期内等待、
`RUN_MINUTES` 超限被忽略、`RUN_MINUTES` 更早被采用。

## 文件

```
keeper.sh                          # 全部逻辑
.github/workflows/instabox-keeper.yml
test/mock_instabox.py              # 假 API
test/run_test.sh                   # 15 条断言
```
