# instabox-keeper

用 GitHub Actions 给 InstaBox 机器做**保活 + 定时轮转**。

跑在 GitHub 的服务器上，所以：不需要你的电脑开机，不需要公网入口，也不需要那台云主机自己活着。
runner 只做一件事——出站访问 `api.instabox.sh`。

## 它解决什么

免费号有两个限制，它们叠加起来会让机器频繁掉线：

| 限制 | 后果 |
|---|---|
| 闲置 **30 分钟**自动挂起（`autoSuspendAfterSeconds=1800`） | 机器一闲就停，全靠下一次 Actions 来捞 |
| 连续运行上限 **120 分钟** | 撞上后强制挂起，冷却会阶梯加码：5–20 → 60–75 → 120–135 分钟 |

**关键：API 的 `maxRunMinutes` 是「阶梯值」，不能用它算阈值。**

2026-11-11 实测同一台机器的返回依次是：

```
运行 55 分钟   → 120
运行 115 分钟  → 150
运行 145 分钟  → 480
```

看起来上限在涨，但**真实执行上限始终是 120 分钟**——到点照样强制挂起。
社区多个项目（`AIR-pixel/instabox-keepalive`、`Matsumiko/instabox-keepalive`）实测确认，
且 `permission_denied: free machines have a managed maxRunMinutes` 无法修改。

如果按「API 值 − 余量」算，第一轮得到 95 分钟；一旦某刻 API 报 480，
就会算出 460 分钟，**直接撞线进冷却**。

所以真实上限用 `MAX_RUN_MINUTES` 显式指定（默认 **120**），API 的值只用于日志对比。
设 `MAX_RUN_MINUTES=0` 才退回用 API 值。

实测（bo1，2026-11-04 ~ 11-10，用 guest agent 每分钟心跳量出来的）：

- 97 次挂起，**全部触发原因是 `idle`**，没有一次是 `maxRun`
- 单次停机中位 **8.8 分钟**，累计每天约 **2.4 小时**
- 挂起前连续活跃时段中位 **44 分钟**，正是「闲 30 分钟 → 挂起」

所以本脚本做两件事：

1. **续 activity lease** —— 每轮跑都续一次（默认 1800 秒），平台就不会因闲置挂起。
   这是真正的「保活」，不是事后抢救。
2. **到点轮转** —— 连续运行接近平台上限时，主动 `suspend → resume` 把计时清零，
   抢在平台强制挂起之前。真实上限用 `MAX_RUN_MINUTES` 指定（默认 120），留 15 分钟余量，105 分钟轮转。

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

日志里应该出现（上限按实际返回值变动）：

```
续租成功，到期 ...
已连续运行 N 分钟（锚点 ...）
真实上限 120 分钟，留 15 分钟余量 → 安全点 105 分钟
还没到 105 分钟，继续跑
```

如果 API 那一刻报的是阶梯值，会这样提示：

```
真实上限 120 分钟（API 当前报 480，属阶梯值，忽略），留 15 分钟余量 → 安全点 105 分钟
```

## 可调参数

都在 workflow 的 `env:` 里：

| 变量 | 默认 | 说明 |
|---|---|---|
| `MAX_RUN_MINUTES` | `120` | **真实**连续运行上限。API 的阶梯值会误导，所以用它覆盖；`0`=退回用 API 值 |
| `ROTATE_MARGIN_MIN` | `15` | 距真实上限还有多少分钟就轮转（社区实践：15–20） |
| `LEASE_TTL` | `1800` | 租约秒数，要明显大于 10 分钟的调度间隔 |
| `LEASE_NAME` | `keepalive` | 租约名 |
| `ROTATE_HOLD_SEC` | `10` | 轮转时暂停多久再恢复 |

**`RUN_MINUTES` 已被废弃。** 现在如果你还传它：

- 比安全点**更早** → 采用它（允许你更保守）
- 比安全点**更晚** → 忽略并告警（防止把机器跑到被平台强制挂起）

注意：`MAX_RUN_MINUTES` 是**锁定真实上限**，不是让它跟随 API 的阶梯值。

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

---

## 实测记录：`maxRunMinutes` 的阶梯值陷阱（2026-11-11）

这是本项目最重要的一条经验，踩过一次才知道。

### 现象

免费机 API 返回的 `maxRunMinutes` 会**阶梯式爬升**。同一台机器、同一次连续运行，
采样记录到的值依次是：

| 时刻 | 已连续运行 | API 报的 `maxRunMinutes` |
|---|---|---|
| 09:32 | 55 分钟 | 120 |
| 10:27 | 110 分钟 | 120 |
| **10:32** | **115 分钟** | **150** ← 第一次上调 |
| 11:02 | 140 分钟 | 150 |
| **11:02** | **145 分钟** | **480** ← 第二次上调 |
| 12:27 | 230 分钟 | 480 |

两次上调都发生在**距当前台阶约 5 分钟**时（115 ≈ 120−5，145 ≈ 150−5）。
另一台机器也在 115 分钟时从 120 跳到 480，规律一致。

### 陷阱：看到的 480 不是真实上限

看到 `480` 容易误以为「能跑 8 小时」。**但真实执行上限始终是 120 分钟。**

2026-11-11 生产环境记录了两次强制挂起，间隔精确等于 120 分钟：

```
12:36:10  轮转完成，计时归零
14:36:15  suspend (max_run)   ← 正好 120 分钟
15:00:40  resume              ← 冷却 24 分钟
17:00:43  suspend (max_run)   ← 又正好 120 分钟
```

社区其他项目也实测确认同一结论：

- `AIR-pixel/instabox-keepalive`：单次运行上限 **120 分钟**，
  `permission_denied: free machines have a managed maxRunMinutes` 无法修改
- `Matsumiko/instabox-keepalive`：
  「`maxRunMinutes`, typically 480; **dynamic runtimes may start at 120**」
  —— 480 是上报上限，120 才是这类动态运行时的真实起点

### 如果按 API 值算会怎样

```
第一轮：120 - 15 = 105 分钟轮转   ✅ 还行
某刻 API 报 480：480 - 15 = 465 分钟轮转   ❌ 120 分钟就被掐了
```

所以必须用 `MAX_RUN_MINUTES=120` 显式锁定，**不能跟随 API 的值**。

### 解决方案

```sh
MAX_RUN_MINUTES=120          # 真实上限，不读 API
ROTATE_MARGIN_MIN=15         # 留 15 分钟余量
# → 105 分钟轮转
```

### 余量怎么定

社区三个项目的实践：

| 项目 | 余量 |
|---|---|
| `Matsumiko/instabox-keepalive` | **15 分钟**（默认） |
| `pingmike2/instabox-keepalive` | **20 分钟** |
| `lexcusishere/instabox-keepalive` | **20 分钟**（「trigger 5 分钟抖动会被 20 分钟吸收」） |

**没有项目用小于 15 分钟。** 因为：

| 动作 | 耗时 |
|---|---|
| GitHub cron 抖动 | 最长可达十几分钟 |
| suspend 请求落地 | 实测 5–15 秒 |
| resume 回来 | 约 5 秒 |

### 冷却会阶梯加码（重要）

`Matsumiko` 文档记录：

> On free plans the penalty grows in steps — roughly **5–20, 60–75, then 120–135 minutes**
> — when caps happen in succession. **A manual pause or stop *before* the max-run is
> reached resets that step ladder**, which is why rotating ahead of the deadline is
> better than running into the cap.

**这就是轮转的真正价值**：不只是避免这一次停机，还能防止冷却时间越滚越长。

### 附带发现

- **闲置挂起真实存在**：`autoSuspendAfterSeconds=1800`，闲 30 分钟就挂。
  用 guest agent 每分钟心跳量过 bo1 一周数据：97 次挂起**全部**由 `idle` 触发，
  平均每天停机约 2.4 小时。所以 activity lease 续租这步不能省。
- **平台会做维护性迁移**：观测到 `suspend succeeded (drain)` → 2.5 分钟后
  `resume succeeded (drain)`。这类停机保活无法避免，但进程不丢。
- **不要用定时轮转点**：曾经配过 `ROTATE_AT`（01:30/08:00/13:00/19:00），
  它优先级高于倒计时，导致两次定点之间（最长 6.5 小时）远超 120 分钟上限，
  机器被强制挂起。**只用倒计时。**

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
