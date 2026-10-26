# Codex CLI 真实 TUI 远程接入与会话接续验证（U3 + U6）

> 状态：**研究文档（RESEARCH ONLY）——待项目经理独立验收。** 本文件不改变产品目标、V1 范围或路线图，不批准任何自动切换功能的施工。
> 关联：[CHATGPT_SUBSCRIPTION_QUOTA_FAILOVER_FEASIBILITY.md](CHATGPT_SUBSCRIPTION_QUOTA_FAILOVER_FEASIBILITY.md) §12 的 U3、U6；[HOT_SWITCH_FEASIBILITY_GATE.md](HOT_SWITCH_FEASIBILITY_GATE.md) §15.4。

## 0. 结论摘要（先读）

**本轮成功的是“真实 Codex CLI TUI + 模拟 Provider”的隔离集成实验，不是 ChatGPT 真实订阅额度耗尽的端到端验证。** 所有上游返回（含额度耗尽）均为本地模拟；未使用真实账户、真实凭据或付费调用。

| 验证项 | 结论 | 证据等级 |
|---|---|---|
| 真实 TUI 通过官方 `--remote` 连接 token 保护的托管 app-server | **PASS** | 本轮实际实验（run7 Tui） |
| Manager 作为第二客户端观察同一线程 | **PASS** | 本轮实际实验 |
| 模拟额度耗尽的结构化信号（Manager 侧）与 TUI 提示 | **PASS** | 本轮实际实验（run7 Exhaustion） |
| 同 Provider 模型切换（Manager `turn/start(model)`），真实 TUI 后续轮次与 `/status` 跟随 | **PASS** | 本轮实际实验 |
| 跨 Provider `thread/fork` 后真实 TUI 接续 | **PARTIAL**：功能可用，但**需要 TUI 手动/由 Manager 重新启动并附着到新线程**（`codex resume <forkId> --remote …`），不是自动无感切换 | 本轮实际实验 |
| 新进程 resume（同一线程 id 换到备用 Provider） | **PARTIAL**：功能可用，但需要停止旧 app-server 并**重新启动 TUI 附着** | 本轮实际实验 |
| U6 同进程 `unsubscribe → resume` 新旧结果矛盾 | **观察结果已解释，内部机制未确认**：在本矩阵条件下，覆盖被忽略的行**都且只**是经历过一次模拟额度耗尽失败轮的线程（相关性，非已证因果；只测了一种失败类型） | 本轮实际实验（0.162 与 0.154 各 14 行） |

## 1. Git 基线与 Codex 版本

| 项 | 值 |
|---|---|
| `origin/main` | `6e811624c540807835e9b73f23e2f3e9cc27d6e4`（Merge PR #105）；main Development Gate run `38252676096`（#326）success |
| 研究分支 / worktree | `research/cli-remote-tui-validation`，`%USERPROFILE%\cmm-wt\cli-remote`（ACL：仅当前用户、SYSTEM、Administrators 可写） |
| 实验输出目录 | `%USERPROFILE%\cmm-wt\cli-lab\`（仓库外，同样 ACL 核验，不提交） |
| Desktop 内置 CLI（主测对象，TUI 与 app-server） | `codex-cli 0.162.0-alpha.17.2`（MSIX `OpenAI.Codex 26.1007.2314.0`） |
| npm CLI（U6 对照） | `codex-cli 0.154.0` |
| 两个版本的 `--remote` 支持 | `codex --help` / `codex resume --help`：`--remote <ADDR>`（`ws://`、`wss://`、`unix://`）与 `--remote-auth-token-env <ENV_VAR>` |
| app-server WebSocket 认证 | `codex app-server --listen ws://127.0.0.1:<port> --ws-auth capability-token --ws-token-sha256 <hex>` |
| 线程状态查询 | 两个版本 schema 均有 `thread/loaded/list` |

## 2. 实验环境、安全隔离与网络限制

- 每个场景使用全新的隔离 `CODEX_HOME`（位于实验输出目录内）；从不选择真实 `~/.codex`，不读取 `auth.json`、API Key 或会话记录。
- 运行前移除进程内所有 `*_API_KEY` 与 `CODEX_LOCAL_ROUTER_TOKEN` 环境变量；Provider token 与 WebSocket token 均为每次运行随机生成的合成值。
- 模拟 Provider（`fake_a`、`fake_b`）只绑定 `127.0.0.1` 随机端口；`m-sub`（模拟订阅模型）在测试指定时刻起返回 429 `usage_limit_reached` + `x-codex-*` 额度头。
- 官方 Codex 自身的外部访问（实验探索阶段发现，见 §10.1）在正式运行前被关闭或拦截：
  - app-server 后台插件同步（`git fetch https://github.com/openai/plugins.git`）：隔离配置 `[features] plugins/remote_plugin/apps/plugin_sharing/skill_mcp_dependency_install = false`；
  - TUI 启动时无条件预取公告提示（官方源码 `codex-rs/tui/src/tooltips.rs` L18–L19 `ANNOUNCEMENT_TIP_URL`，`codex-rs/tui/src/lib.rs` L1159 `announcement::prewarm`，标签 `rust-v0.162.0-alpha.17.2`）：子进程 `HTTP(S)_PROXY/ALL_PROXY` 指向已关闭的本地端口，`NO_PROXY=127.0.0.1,localhost,::1`；
  - `check_for_update_on_startup = false`，并在出现 “Update available” 时中止（未出现）。
- 每一步记录实验自身进程树的非回环 TCP 连接；**run7、run8、run9 全部步骤均为 0**。
- 真实 TUI 运行在 Windows ConPTY 中（`CreatePseudoConsole`，官方 Win32 API）；没有使用私有 IPC、UI 注入、Desktop 数据库或 `\\.\pipe\codex-ipc`；没有接触 Codex Desktop 自身的 app-server（PID 18632 全程存活且未连接）。
- run7–run9 运行时：所有子进程按 PID 加入**同一个** kill-on-close Windows Job Object，并受 `-MaxSeconds` 看门狗约束；外部连接按步骤采样记录（非熔断）。每步增量写入 `progress-<场景>.log` 与 `result-<场景>.json`。提交后的执行器已按 §10.4、§10.5 整改（独立 Job、挂起创建后按句柄加入、网络熔断且 fail-closed、退出码、唯一空目录），整改后版本未再运行实验，且**默认禁止运行**（§10.5）。
- 零付费调用、零真实账户接口调用。

## 3. 正式运行记录（run7 / run8 / run9，按执行顺序）

| 顺序 | 运行 | 场景 / 版本 | 时间（+08:00） | 状态 | 说明 |
|---|---|---|---|---|---|
| 1 | run7 | Tui / 0.162（`-MaxSeconds 120`） | 22:04:59 → 22:05:20（21 s） | **COMPLETED** | 9 步，0 超时，0 外部连接 |
| 2 | run7 | Exhaustion / 0.162（`-MaxSeconds 300`） | 22:05:31 → 22:06:21（50 s） | **COMPLETED** | 7 步，0 超时，0 外部连接 |
| 3 | run7 | U6 / 0.162 + 0.154（`-MaxSeconds 420`） | 22:06:42 → 22:06:44（2 s） | **ERROR（测试工具故障）** | `Set-StrictMode 3.0` 下读取哈希表不存在的键 `$Opt.override` 抛错；未执行任何实验步骤 |
| 4 | run8 | U6 / 0.162 + 0.154（`-MaxSeconds 420`） | 22:07:26 → 22:09:53（147 s） | **ERROR（测试工具故障）** | 0.162 矩阵 14 行完成并保存；0.154 新进程 stdio 客户端启动失败：`failed to initialize sqlite state runtime`（见 §10） |
| 5 | run9 | U6 / 0.154（`-MaxSeconds 420`） | 22:11:23 → 22:12:24（61 s） | **COMPLETED** | 14 行，0 超时，0 外部连接 |

结果文件（仓库外，开发者本机）：`cli-lab\run7\result-{Tui,Exhaustion,U6}.json`、`cli-lab\run7\progress-*.log`、`cli-lab\run8\result-U6.json`、`cli-lab\run8\progress-U6.log`、`cli-lab\run8\u6-extra1\stdio-np1.err`、`cli-lab\run9\result-U6.json`、`cli-lab\run9\progress-U6.log`。每次运行结束后实验进程残留数均为 0。

两次 ERROR 均为**测试工具故障**，不是 Codex 产品故障。故障与重试的执行纪律问题见 §10。

## 4. 真实 TUI 连接与认证（run7 Tui）

| 步骤 | 观察 | 结论 |
|---|---|---|
| 无 token / 错误 token 连接 | 均为 `HTTP 401`（`The server returned status code '401' when status code '101' was expected`） | PASS |
| 真实 TUI 启动（`codex --remote ws://127.0.0.1:<port> --remote-auth-token-env CRR_WS_TOKEN -C <workspace>`） | 渲染版本横幅与输入框 `› Ask Codex to do anything`，状态栏显示 `m-sub` | PASS |
| 第 1 轮输入 | 上游 `fake_a/m-sub`，主线程 4 个输入项；TUI 渲染模拟回复 | PASS |
| 第 2–4 轮 | 同一主线程，输入项 4 → 6 → 8 → 10，历史连续 | PASS |
| TUI Ctrl+C 退出 | TUI 退出；app-server 存活；线程仍在 `thread/loaded/list` 中 | PASS |
| 重新附着 `codex resume <threadId> --remote …` | 渲染历史回复，下一轮继续同一线程（10 个输入项） | PASS |

TUI 退出时会打印官方提示：“Disconnected from this task. Any running work continues. To reconnect, run: `codex --remote ws://…/ --remote-auth-token-env CRR_WS_TOKEN resume <threadId>`”。

附带观察：0.162 TUI 每个用户轮次有时会在另一个 **ephemeral 辅助线程**上多发一个 `kind=turn` 请求（run2 中 1 个，run7 中 0 个）；`thread/read` 对其返回 “ephemeral threads do not support includeTurns”。其用途未确认；不影响主线程结论（测试按线程 id 匹配主线程请求）。

## 5. Manager 双客户端观察（run7 Tui）

- Manager（第二个 WebSocket 客户端，同一 token）通过 `thread/loaded/list` + `thread/read` 识别主线程，`thread/resume {threadId}` 订阅。
- 订阅后，TUI 发起的轮次被 Manager 实时观察到：`turn/started`、`item/started`、`item/completed`、`turn/completed`、`thread/status/changed`、`thread/tokenUsage/updated`、`account/rateLimits/updated`。
- Manager 断开并重新连接、重新订阅后，TUI 后续轮次不受影响。
- 未观察到连接、认证或会话冲突。

## 6. 模拟额度耗尽信号（run7 Exhaustion）

- 第 1 轮正常；测试将 `m-sub` 标记为耗尽后，TUI 第 2 轮上游返回 429 `usage_limit_reached`。
- Manager 收到：`turn/completed(status=failed)`、`error.codexErrorInfo = "usageLimitExceeded"`、`account/rateLimits/updated`（primary 100%、`rateLimitReachedType = rate_limit_reached`）。
- 真实 TUI 显示 “You’ve hit your usage limit …”。
- **官方降级提示**：真实 TUI 随即弹出 “Approaching rate limits — Switch to gpt-6-luna for lower credit usage? 1. Switch to gpt-6-luna / 2. Keep current model / 3. Keep current model (never show again)”。官方源码 `codex-rs/tui/src/chatwidget/rate_limits.rs`（`rust-v0.162.0-alpha.17.2`）：`RATE_LIMIT_SWITCH_PROMPT_THRESHOLD = 90.0`，仅在当前模型不是 `gpt-6-luna` 且目录中存在该模型时显示，可由本地设置 `notices.hide_rate_limit_model_nudge` 隐藏。它只在官方目录内切换，且需要用户选择。
- 正式运行中测试按 Esc 退出该提示，**未选择任何选项**；随后下一轮模型保持为 Manager 设置的 `m-alt`，没有被误确认为 `gpt-6-luna`。

## 7. 同 Provider 切换（run7 Exhaustion，场景 A）

| 步骤 | 观察 | 结论 |
|---|---|---|
| Manager `turn/start {threadId, model:"m-alt", input:[合成文本]}` | 被接受；上游 `fake_a/m-alt`，同一主线程，`turn/completed` | PASS |
| 真实 TUI 是否显示该轮 | 渲染该轮模拟回复 | PASS |
| 真实 TUI 下一个用户轮次 | 上游 `fake_a/m-alt`（粘性） | PASS |
| 真实 TUI `/status` | 报告模型 `m-alt` | PASS |

注意：`turn/start` 必须携带输入；本实验注入的是合成文本，**不是重放失败轮的用户输入**。

## 8. 跨 Provider fork 与新进程 resume（run7 Exhaustion，场景 B / C / C2）

| 场景 | 步骤与观察 | 结论 |
|---|---|---|
| B fork | Manager `thread/fork {threadId, modelProvider:"fake_b", model:"m-b"}` → 新线程 id，设置 `fake_b/m-b`。原 TUI 仍停在原线程（其下一轮继续 `fake_a/m-alt`）。测试以 Ctrl+C 退出原 TUI，再启动 `codex resume <forkId> --remote …`：渲染历史，下一轮上游 `fake_b/m-b`（15 个输入项，包含此前全部标记）；`/status` = `m-b`；原线程仍可 `thread/read` | **PARTIAL**：上下文保留，但**需要重新启动 TUI 并附着到新线程**；TUI 不会自动跟随 fork |
| C 新进程 resume | 停止旧的隔离 app-server（本测试自身启动的进程），启动新 app-server；Manager `thread/resume {原 threadId, modelProvider:"fake_b", model:"m-b"}` 返回 `fake_b/m-b`；重新启动 TUI `resume <原 threadId>`：下一轮上游 `fake_b/m-b`，**同一线程 id**，17 个输入项；`/status` = `m-b` | **PARTIAL**：同一线程换到备用 Provider 成功，但需要重启 app-server 并**重新附着 TUI** |
| C2 仅 TUI resume | 再换一个新 app-server，不经 Manager，直接 `resume <原 threadId>`：上游 `fake_b/m-b`（设置已持久化） | PASS（持久化行为） |

## 9. U6：同进程 `unsubscribe → resume` 的 14 行矩阵

每行一个新线程；`S*` = stdio 传输，`W*` = WebSocket，`N*` = 新进程（线程由一个 stdio 进程创建后关闭，再由新 stdio 进程 resume）。resume 目标：同 Provider 为 `model:"m-alt"`；跨 Provider 为 `modelProvider:"fake_b", model:"m-b"`。随后发送不带 model 的普通轮次，记录实际上游。

| 行 | 失败轮 | 成功的 `turn/start(model)` 覆盖 | 跨 Provider | 等待 | unsubscribe 后仍在 loaded 列表 | 0.162 resume 结果 → 下一轮上游 | 0.154 resume 结果 → 下一轮上游 |
|---|---|---|---|---|---|---|---|
| S1 / W1 | 否 | 否 | 否 | 0 | 是 | 生效 → `fake_a/m-alt` | 生效 → `fake_a/m-alt` |
| S2 / W2 | 否 | 是 | 否 | 0 | 是 | 生效 → `fake_a/m-alt` | 生效 → `fake_a/m-alt` |
| S3 / W3 | **是** | 否 | 否 | 0 | 是 | **忽略** → 仍为原（已耗尽）模型 | **忽略** |
| S4 / W4 | **是** | 是 | 否 | 0 | 是 | **忽略** → 仍为覆盖后的（已耗尽）模型 | **忽略** |
| S5 / W5 | 否 | 否 | 是 | 0 | 是 | 生效 → `fake_b/m-b` | 生效 → `fake_b/m-b` |
| S6 / W6 | 否 | 否 | 否 | 10 s | 是 | 生效 → `fake_a/m-alt` | 生效 → `fake_a/m-alt` |
| N1 | 否 | 否 | 否 | — | 不适用 | 生效 → `fake_a/m-alt` | 生效 → `fake_a/m-alt` |
| N2 | 否 | 否 | 是 | — | 不适用 | 生效 → `fake_b/m-b` | 生效 → `fake_b/m-b` |

来源：0.162 = `run8\result-U6.json` 的 `u6_primary`（14 行）；0.154 = `run9\result-U6.json` 的 `u6_primary`（14 行）。stdio 与 WebSocket 结果完全一致。

**历史差异解释**：`HOT_SWITCH_FEASIBILITY_GATE.md` §15.4 A5 的线程没有失败轮（形态对应 S1，本矩阵中生效）；M1 研究 E2b V1 / E2c 的线程先经历了失败轮（形态对应 S3/S4，本矩阵中忽略）。两种历史结果都在本矩阵中被复现；在本矩阵内，版本（0.162 / 0.154）与传输（stdio / ws）都没有改变结果。另外 `thread/loaded/list` 显示 unsubscribe 在所有行都**没有真正卸载线程**。

**U6 结论（收窄）：观察结果已解释，内部机制未确认。**

- 能说的：在本矩阵（每行新建线程、单客户端、两个版本、两种传输）中，同进程 resume 覆盖被忽略的行，**恰好都是**先经历过一次“模拟 429 `usage_limit_reached` 失败轮”的线程；其余行均生效。这是**相关性观察**，与历史两组结果一致。
- 不能说的：不能断言“失败轮是唯一或普遍的决定因素”。本轮只测了一种失败类型（模拟额度耗尽），没有测 5xx、网络中断、取消、工具失败等其他失败；没有测失败后又成功一轮的线程；没有测多客户端同时订阅的情形；也没有在源码中定位被忽略的原因。
- 新进程 resume（N1/N2）在本矩阵中均生效；但 N1/N2 没有失败轮，失败轮线程的新进程 resume 只在 run7 Exhaustion 场景 C（跨 Provider，生效）中观察到一次。

## 10. 实验工具故障、整改过程与执行纪律

### 10.1 正式运行前的探索阶段（结果已作废，不计入结论）

| 运行 | 问题 | 原因（均为测试工具或实验设置） | 整改 |
|---|---|---|---|
| smoke（第 2 次） | 运行挂起约 3 分钟 | app-server 自行启动插件同步 `git fetch`（外部网络），子进程继承输出管道导致父进程等待 | 隔离配置关闭插件类 features |
| run1 Tui | 2 个外部连接；线程匹配错误 | TUI 启动预取 GitHub 公告；测试取了辅助线程的请求 | 代理重定向到关闭端口；按线程 id 匹配 |
| diag | 挂起约 5 分钟 | 诊断脚本报错未清理，孤儿 app-server 持有管道 | 引入 kill-on-close Job Object 与 `finally` 清理 |
| run2 Exhaustion | 结果作废 | 测试输入被 TUI 官方降级提示吞掉，回车选择了 `gpt-6-luna`（仅隔离环境） | 检测提示后按 Esc 退出，不选择任何选项 |
| run3–run5 | 部分步骤 UNKNOWN / TIMEOUT | 快速输入丢失需 Shift 的字符；正则转义错误（C# `"\b"`）；在 TUI 加载期间输入导致字符乱序 | 改为小写数字标记；修正正则；启动后等待屏幕稳定 |
| run6 | 被外部中断，无结果文件 | 中断导致 `finally` 未执行 | 每步增量写日志与结果；Job Object 保证子进程随之终止 |

### 10.2 正式阶段的两次 U6 异常与重试（如实记录）

1. **run7 U6（22:06:42，ERROR）**：`Set-StrictMode -Version 3.0` 下 `$Opt.override` 读取不存在的哈希表键抛错。开发者将可选参数读取改为 `$Opt['override']` 形式，然后**自行**以 run8 重跑。
2. **run8 U6（22:07:26，ERROR）**：0.162 矩阵完成；0.154 的新进程 stdio 客户端失败，stderr 为 `failed to initialize sqlite state runtime under …\run8\u6-extra1\codex-home`。原因判断：同一隔离 `CODEX_HOME` 上，前一个被强制停止的 app-server 尚未完全退出，下一个 Codex 进程即开始初始化状态库（属于测试工具的进程生命周期管理问题；0.162 未触发）。开发者改为“停止后等待进程真正退出（≤10 s）”“stdio / ws / 新进程三个阶段各用独立 `CODEX_HOME`”“U6 行逐行保存”“stdio 客户端强制终止后等待退出”，然后**再次自行**以 run9 仅重跑 0.154 并完成。
3. **执行纪律**：项目经理此前规定测试工具异常后必须停止报告、不得自行重试。上述两次修复与重跑**超出了当次授权**。两次失败记录均完整保留（`run7\result-U6.json`、`run8\result-U6.json`、`run8\u6-extra1\stdio-np1.err`），未删除或改写。今后遇到新的异常将立即停止并报告。
4. 两次 ERROR 均为测试工具故障，**不归类为 Codex 产品故障**。

### 10.3 提交前的静态安全修订（未重新运行实验）

第一次提交（`9a975b7`）前，只对执行器做了两处不影响实验逻辑的安全修订：`-Codex` 改为必填参数（去掉含本机安装哈希目录的默认路径）；`--version` 探测也在隔离 `CODEX_HOME` 下执行。

### 10.4 第二轮安全整改（PR #106，静态验证；未重新运行实验）

按项目经理要求，对执行器做了以下整改。**整改后的执行器没有再运行任何 TUI / Exhaustion / U6 实验**；因此 run7–run9 的结果来自整改**前**的执行器（`9a975b7` 中的版本），整改后版本的动态行为**未验证**。

| 整改项 | 内容 |
|---|---|
| Job Object 安全 | 每个由执行器启动的根进程拥有**独立**的 kill-on-close Job Object；通过启动时取得的**进程句柄**加入（不再按 PID `OpenProcess`）；真实 TUI 以 `CREATE_SUSPENDED` 创建、先入 Job 再 `ResumeThread`，其子进程不可能先于入 Job 产生。残余风险：app-server 用 `Start-Process` / `Process.Start` 启动，无法挂起，启动瞬间到入 Job 之间若产生子进程则不在 Job 内（未验证是否会发生）——已在 §10.5 第 1 项改为挂起创建。 |
| PID 身份保护 | 删除按父 PID 推断进程树的逻辑；清理与网络检查都使用 Job Object 的**权威成员列表**（`JobObjectBasicProcessIdList`），终止只针对 Job 成员（`TerminateJobObject`），并等待 `ActiveProcesses == 0`（≤10 s），不会因 PID 复用误杀无关进程。 |
| Junction 防护 | `OutDir`、其所有已存在的上级目录、以及执行器创建的每个目录都不得是重分析点（junction / symlink），创建前后各检查一次；`OutDir` 不得位于仓库内。 |
| 网络熔断 | 后台 Supervisor 每 500 ms 通过 `GetExtendedTcpTable`（IPv4 + IPv6）检查所有 Job 成员的 TCP 连接；一旦出现非回环远端，立即终止全部 Job 并标记 `NETWORK_VIOLATION`。仍只覆盖 TCP（UDP 未覆盖）。 |
| 超时与退出码 | Supervisor 同时执行 `-MaxSeconds` 墙钟预算，超时立即终止全部 Job。脚本退出码：0 COMPLETED，2 安全守卫拒绝，3 ERROR，4 TIMEOUT，5 NETWORK_VIOLATION（此前无论结果都以 0 退出）。 |

整改后已执行的验证（均不启动 Codex）：PowerShell 解析、C# 编译、Job / TCP 表 API 健全性检查（空 Job、仅本 PowerShell 进程的连接表）、三个守卫负例——`OutDir` 在 `%TEMP%`、`OutDir` 在仓库内、`OutDir` 经过 junction——均以退出码 2 拒绝且未创建目录（使用不存在的 `-Codex` 路径，确保不可能启动 Codex）。

### 10.5 第三轮最小整改（PR #106 复核遗留五项，静态验证；未重新运行实验；执行器默认禁止运行）

项目经理对 §10.4 版本复核后指出五项遗留问题。本轮只针对这五项做最小整改，只改动执行器、装置与本报告；未修改生产代码、未扩展测试框架、未运行任何 TUI / Exhaustion / U6 实验。

| # | 遗留问题 | 整改 |
|---|---|---|
| 1 | app-server 启动后才绑定 Job 的竞态 | 新增 `JobProcess`：ws app-server、stdio app-server 以及 `codex --version` 探测都以 `CREATE_SUSPENDED` 创建，按 `CreateProcess` 返回的句柄加入各自的 kill-on-close Job 后才 `ResumeThread`（与真实 TUI 相同）；不再使用 `Start-Process` / `Process.Start`。子进程只继承三个标准句柄（`PROC_THREAD_ATTRIBUTE_HANDLE_LIST`）；stdout/stderr 写入新建文件（`CreateNew`），stdin 为执行器持有的管道。`--version` 探测此前不在任何 Job 内，属同一类问题，一并纳入。 |
| 2 | 网络监控 API 失败时未 fail-closed | `JobObjectBasicProcessIdList` 查询失败、成员列表不完整（含缓冲区不足重试仍失败）、`GetExtendedTcpTable` 返回非预期错误码或行数不一致时一律抛错；Supervisor 将其记录为 `monitor-failure: …`，立即终止全部 Job，并以 `NETWORK_VIOLATION`（退出码 5）结束——无法观测的网络状态按违规处理，不再当作“无连接”。熔断后 Supervisor 拒绝登记新的进程组，阻止熔断后再启动进程。 |
| 3 | Supervisor `Timer.Dispose` 未同步回调 | 回调互斥（不重叠执行）；`Dispose` 先置停止标志，再用 `Timer.DisposeAsync()` 等待正在执行的回调结束（有界），随后做最后一次 fail-closed 扫描并在锁内终止、释放全部 Job。执行器在 `Dispose` **之后**才计算最终状态；若回调未能确认结束，`COMPLETED` 降级为 `ERROR`（`supervisorDrained=false`）。 |
| 4 | 实验目录没有强制唯一空目录 | `OutDir` 必须**尚不存在**；执行器使用的每个目录（`OutDir`、各场景目录、`codex-home`、`workspace`、`version-probe-home`）都必须由本次运行新建：已存在即拒绝（退出码 2），新建后再次检查无重分析点且为空。子进程的 stdout/stderr 文件以 `CreateNew` 创建，不会写入已有文件。 |
| 5 | 软超时仍可能返回 COMPLETED | 任何步骤软超时（`Wait-Upstream` / `Wait-Note` / TUI 未渲染）或 RPC 请求无应答（ws 与 stdio 客户端统一记录到 `rpcTimeouts`）都会使 `COMPLETED` 变为 `TIMEOUT`（退出码 4，`timeoutKind=step`）；墙钟预算耗尽为 `timeoutKind=budget`。 |

**限制与默认禁止运行**：上述整改只做了静态验证，其在真实 Codex 进程上的动态行为（挂起创建与入 Job、句柄继承、fail-closed 熔断、回调同步、超时分级）**未验证**，因此不宣称执行器已安全。执行器现在**默认拒绝运行**（退出码 2）；只有在老板 / 项目经理明确批准一次动态验证后，才可显式传入 `-AllowUnverifiedRunner`。按新的状态规则，run7–run9 的结论不受影响：这些运行由 `9a975b7` 版本产生，记录的超时数均为 0（§3）；但该旧版本不记录 RPC 超时，旧结果在“RPC 软超时”这一维度上**无法回溯判定**。

本轮已执行的验证（均不启动 Codex、不创建任何子进程）：PowerShell 解析 0 错误；C# 编译通过；API 健全性——空 Job 成员数 0、仅本 PowerShell 进程的 TCP 表查询无错误且 0 个非回环连接、无进程组时 Supervisor 启动/释放后 `DrainedCleanly=True` 且未熔断、预算为 0 时熔断为 `TIMEOUT` 且之后拒绝登记新进程组、释放后拒绝登记；守卫负例——未传 `-AllowUnverifiedRunner`、`OutDir` 已存在、`OutDir` 在 `%TEMP%`、`OutDir` 在仓库内——均以退出码 2 拒绝，且未创建任何目录（使用不存在的 `-Codex` 路径）。

## 11. 可复现方法（脱敏）

复现装置：`tests/fixtures/codex-cli-remote-research/Invoke-RemoteResearch.ps1` 与 `RemoteResearchHarness.cs`（仅 .NET 内置库，运行时由 `Add-Type` 编译；不参与 CI，不在任何构建中自动运行）。

注意：仓库中的执行器是 §10.4、§10.5 整改后的版本，**默认禁止运行**，需经批准后显式传入 `-AllowUnverifiedRunner`；产生本报告 run7–run9 结果的是整改前版本（`9a975b7`）。退出码：0 COMPLETED、2 安全守卫拒绝、3 ERROR、4 TIMEOUT（预算耗尽或任一步骤 / RPC 软超时）、5 NETWORK_VIOLATION（含网络监控失败）。

```powershell
# OutDir 必须是绝对路径、不在 %TEMP% 下、不在仓库内、路径中无 junction/symlink、尚不存在
# （每次运行使用新的唯一目录），且只允许当前用户/SYSTEM/Administrators 写入。
# 仅在获得老板 / 项目经理对动态验证的明确批准后才加 -AllowUnverifiedRunner。
pwsh -NoProfile -File tests/fixtures/codex-cli-remote-research/Invoke-RemoteResearch.ps1 `
  -OutDir <新的 ACL 合规目录> -Codex <codex.exe 路径> -Scenario Tui -MaxSeconds 120 -AllowUnverifiedRunner
pwsh -NoProfile -File tests/fixtures/codex-cli-remote-research/Invoke-RemoteResearch.ps1 `
  -OutDir <新的 ACL 合规目录> -Codex <codex.exe 路径> -Scenario Exhaustion -MaxSeconds 300 -AllowUnverifiedRunner
pwsh -NoProfile -File tests/fixtures/codex-cli-remote-research/Invoke-RemoteResearch.ps1 `
  -OutDir <新的 ACL 合规目录> -Codex <codex.exe 路径> -Scenario U6 -MaxSeconds 420 -AllowUnverifiedRunner
```

测试数据全部为合成值：模型 `m-sub`、`m-alt`、`m-b`、`m-s*`、`m-w*`、`m-n*`；Provider `fake_a`、`fake_b`；TUI 输入标记 `mk[a-z0-9]+`；Manager 注入标记 `MARK_*`。输出为 `result-<场景>.json`（每步结构化字段、外部连接、超时列表、上游请求摘要）、`progress-<场景>.log` 与 `screen-*.txt`（TUI 去除控制序列后的屏幕文本）。

**可复核状态**：官方协议/源码位置可独立核对；本轮实验结果是**开发者在本机运行的结果，尚未由第三方独立复现**。真实 TUI 实验依赖 Windows ConPTY 与已安装的 Codex 二进制。

## 12. 失败模式与任务安全分析

| 风险 | 观察 / 依据 | 处理建议 |
|---|---|---|
| 自动重放失败轮输入可能重复工具副作用 | `turn/start` 必须带输入；本轮只注入合成文本 | 产品设计中不得自动重放；如何继续由老板决定 |
| 官方降级提示与 Manager 自动切换并存 | 真实 TUI 在耗尽时弹出官方提示；若用户或脚本误按回车会切到官方便宜模型 | 设计时必须考虑两者交互；测试中只按 Esc |
| fork 产生新线程 id | TUI 不会自动跟随 | 需要“重新附着”流程与用户可见提示，不能宣称无感 |
| 失败轮后同进程 resume 被忽略 | U6 S3/S4、W3/W4 | 跨 Provider 接续只能依赖 fork 或新进程 resume |
| 托管 app-server 被其他本地进程连接 | 无/错 token 均 401 | 需要 token 文件 ACL 与生命周期规则（参照 PR10A/10B） |
| 官方 Codex 自身外部访问 | 插件同步、公告预取 | 产品若托管 app-server，需要明确网络策略说明 |
| 测试工具输入可靠性 | 需 Shift 的字符丢失、加载期输入乱序 | 仅影响测试装置；不是产品结论 |

## 13. 仍未验证的风险（NOT VERIFIED / UNKNOWN）

1. 真实 ChatGPT 订阅额度耗尽的端到端行为（U1，需老板批准）。
2. 真实第三方备用 Provider 接受跨 Provider 历史（含加密 reasoning）的行为（U4，付费，需批准）。
3. 失败轮后同进程 resume 被忽略的内部机制（U6 机制 UNKNOWN）。
4. 0.162 每轮 ephemeral 辅助线程请求的用途与出现条件。
5. 真实账户下官方降级提示与 `rateLimitsByLimitId` 的实际表现（U2/U5）。
6. remote 模式下用户在 TUI 内手动 `/model` 的协议表现（U9，本轮未执行）。
7. 托管 app-server 长时间运行、多 TUI 同时附着、跨重启的稳定性。
8. 第三方独立复现。
9. §10.4、§10.5 整改后执行器的动态行为（挂起创建与入 Job、网络熔断及 fail-closed、Supervisor 回调同步、超时分级在真实 Codex 进程上的表现）——整改后未运行实验，执行器默认禁止运行，需单独批准。
10. U6 中“失败轮”以外的失败类型、失败后再成功的线程、多客户端订阅下的 resume 行为。

## 14. 对原架构与 V1 的影响

- **Direct Mode / Router / Desktop**：本轮未修改任何生产代码；Router 的 fail-closed 规则不变。
- **CLI 托管会话网关（候选方案）**：本轮证据支持“Manager 托管 app-server + 真实 TUI `--remote` + Manager 观察”在隔离环境中可行；同 Provider 切换可以原线程、真实 TUI 跟随；跨 Provider 需要 fork/新进程 resume **并重新附着 TUI**。该方案**仍是候选方案，未经批准不得施工**。
- **V1-11**：技术判断从“TUI 接续未验证”推进为“CLI 在模拟环境下可接续，但跨 Provider 需重新附着、真实订阅信号未验证”；V1 范围仍由老板在 M2 决定，本研究不改变 V1 决策清单。
- **新增约束**：任何自动切换设计都必须与官方 TUI 的降级提示共存，并避免自动重放失败轮。

## 15. 下一步技术建议（均需单独批准）

1. **最小下一步**：仅文档/设计——为“跨 Provider 重新附着”写出用户可见流程与失败处理（不施工）。
2. 经老板批准后进行 U2（真实账户只读查询两次账户接口）以确认真实额度字段。
3. 若要理解 U6 机制，可在官方源码中定位失败轮后 resume 覆盖被忽略的路径（只读研究）。
4. 在任何施工前，由老板决定 CLI 托管会话形态是否纳入 V1-11。
