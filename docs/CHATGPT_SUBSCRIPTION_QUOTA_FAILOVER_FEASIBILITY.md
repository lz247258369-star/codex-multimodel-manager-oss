# M1 — ChatGPT 订阅额度耗尽自动切换：技术可行性研究

> 状态：**研究文档（RESEARCH ONLY）——待项目经理独立验收。** 本文件不改变任何产品目标、V1 范围或路线图结论，不批准 M2 范围冻结、HS-1C 重建或任何施工。
> 适用目标：[PRODUCT_VISION.md](PRODUCT_VISION.md) §2 的 G-1…G-6；对应 [MASTER_ROADMAP.md](MASTER_ROADMAP.md) 的 V1-11 与 M1。
> 证据等级：**A** 官方协议/官方源码/官方文档；**B** 隔离环境实际实验；**C** 真实 Desktop / CLI 集成环境验证；**D** 真实 ChatGPT 订阅额度耗尽端到端验证。**本研究所有结论最高为 A/B；没有任何 C 或 D 证据。**

## 1. 研究摘要与最终结论

**总体结论：PARTIALLY_FEASIBLE**（部分可行；无端到端验证）。

| 场景 | 结论 | 最高证据 | 一句话理由 |
|---|---|---|---|
| 识别“ChatGPT 订阅额度耗尽”信号 | **PARTIAL** | A + B | 官方协议有结构化信号（`codexErrorInfo = usageLimitExceeded` + `account/rateLimits/updated`），但 `usageLimitExceeded` 同时覆盖订阅额度、API Key 额度与“套餐不含”，必须结合 Provider 身份与额度快照才能区分；且只能通过 app-server 协议获得，`codex exec --json` 与 Desktop 都不向外部提供结构化信号。 |
| **Codex CLI** 自动切换到已批准备用模型 | **PARTIAL** | B | 在“Manager 托管 app-server + CLI 以 `--remote` 连接”的形态下：信号可观察（B）、同 Provider 内可原线程切换（B）、跨 Provider 只能 fork 或新进程 resume（B，历史可保留），但真实 TUI 重新附着、真实备用 Provider 接受历史回放均 **NOT VERIFIED**；另外，本研究捕获的 2 个 Codex 0.162 请求样本被当前 Local Router 解析器按 fail-closed 设计拒绝（见 §5.5），以 Router 为备用执行层存在**待确认的兼容性阻断风险**。 |
| **Codex Desktop** 自动切换 | **BLOCKED**（本机 Desktop `26.1007.2314.0` / 内置 `codex-cli 0.162.0-alpha.17.2`，Windows） | A + B | Desktop 的 app-server 仍走 Desktop 私有的 stdio；无官方外部控制通道；`app-server daemon` 需要官方 standalone 安装且 Desktop 并未使用；ChatGPT 订阅流量为 `DIRECT_ONLY`，Router 也看不到。daemon/remote 路径能否附着本地 Desktop 为 **UNKNOWN**。 |
| G-3 不误切（普通 429、超时、5xx、网络、慢响应） | **SUPPORTED（分类层面）** | B | 实验中这些情况从未被归为 `usageLimitExceeded`。 |
| G-6 全部备用不可用时有界停止 | **PARTIAL** | A（Draft #88 代码阅读） | HS-1C 只遍历显式 `fallback_route_ids` 一次、跳过已耗尽项；但全部失败时只返回原始错误，没有明确的“全部备用不可用”状态与记录。 |

**证据可复核性**：A 级证据（官方 Schema、官方源码固定标签、本仓库代码）可按附录 A.1 独立核对；所有 B 级实验结论均为**开发者报告，待独立复现**（附录 A.8），本研究不宣称已完成独立验证。ChatGPT 订阅额度与 OpenAI API 额度是两个不同来源，本研究的全部结论均不以 OpenAI API 额度替代订阅额度。

**能否实现“真正的自动切换”？** 当前证据不足以证明。CLI 存在一条由官方协议组成的候选路径，各段在隔离环境中分别验证（B），但缺少 C/D；Desktop 在当前版本被平台边界阻断。**这不是永久不可能**：阻断点是具体版本的具体缺口（见 §12）。

**是否需要额外接口？** 需要：订阅耗尽分类器、Manager 托管会话网关、跨 Provider 线程迁移编排、Router 对真实 Codex 请求的兼容层（含加密 reasoning 历史处理策略）、“全部备用不可用”状态与切换历史。

**是否打乱现有主架构？** 不需要推倒 Router，也不改变 Direct Mode 默认行为；但 CLI 路径要求新增一个 opt-in 的“Manager 托管会话”运行形态，这是新的产品形态，需要老板决定。

### 1A. 研究矩阵 — Codex CLI

| 技术路径 | 信号来源 | 是否 ChatGPT 订阅额度 | 信号可观察性 | 误判风险 | 可否自动触发 | 可否切到已批准备用 | 原线程/原任务能否保留 | 手动切换是否优先 | 失败能否安全停止 | 所需代码改动 | 证据等级 | 官方支持 | 结论 |
|---|---|---|---|---|---|---|---|---|---|---|---|---|---|
| C1 托管 app-server + `--remote`（同 Provider 备用） | app-server `error` + `account/rateLimits/updated` | 是（需 §4.3 多条件） | 高（B） | 中（错误码合并，靠身份+快照区分） | 是（B） | 是，`turn/start(model)`（B） | 原线程保留（B）；需携带输入 | 设计可保证（CAS）；TUI `/model` 表现未验证 | 是：Manager 侧有界逻辑（设计） | 分类器、网关、编排、V4 | A+B | 协议官方；`--remote`/ws 标注实验性 | PARTIAL |
| C1 托管 app-server + `--remote`（跨 Provider 备用） | 同上 | 同上 | 高（B） | 同上 | 是（B） | fork / 新进程 resume（B）；经 Router 时，本研究样本被拒（B，样本范围内；§5.5） | 历史保留但**线程 id 变化**（fork）或需卸载（新进程）；TUI 重新附着未验证 | 同上 | 同上 | 同上 + Router 兼容 + reasoning 回放策略 | A+B | 同上 | PARTIAL |
| C2 `codex exec --json` | `turn.failed` 文本 | 无法可靠判断 | 低（仅文本） | 高 | 否（不建议） | 新会话可以，非接续 | 否 | — | — | — | A | 官方 | BLOCKED（不满足 G-2 判定要求） |
| C3 官方 daemon + TUI 自动附着 | 同 C1 | 同 C1 | 未验证 | 同 C1 | 未验证 | 未验证 | 未验证 | 未验证 | 未验证 | 需 standalone 安装 | A | 官方（实验性） | UNKNOWN |
| C4 新会话 + Git handoff（现有） | — | — | — | — | 否 | 是（新会话） | 只保留工作区，不保留对话 | 是 | 是 | 无 | 已在 main | — | 不满足“自动接续”，仅可作降级参考 |
| Router 侧检测 | 无（ChatGPT 流量不经 Router） | — | 不可观察 | — | 否 | — | — | — | — | 需代理账户凭据（禁止） | 架构约束 | — | BLOCKED（边界） |

### 1B. 研究矩阵 — Codex Desktop（MSIX 26.1007.2314.0 / 内置 0.162.0-alpha.17.2，Windows）

| 技术路径 | 信号来源 | 是否 ChatGPT 订阅额度 | 信号可观察性 | 误判风险 | 可否自动触发 | 可否切到已批准备用 | 原线程/原任务能否保留 | 手动切换是否优先 | 失败能否安全停止 | 所需代码改动 | 证据等级 | 官方支持 | 结论 |
|---|---|---|---|---|---|---|---|---|---|---|---|---|---|
| 附着运行中 Desktop 的 app-server | Desktop 私有 stdio | 是 | **外部不可观察** | — | 否 | 否 | — | — | — | 无官方通道 | A+B | 无 | BLOCKED |
| 官方 daemon / remote-control | 同 C1 | 是 | 未知 | — | 未知 | 未知 | 未知 | 未知 | 未知 | standalone 安装 + 未知 Desktop 支持 | A | 实验性，Desktop 本地附着未说明 | UNKNOWN |
| Router 侧检测 | 无（`DIRECT_ONLY`） | — | 不可观察 | — | 否 | — | — | — | — | 需代理账户凭据（禁止） | 架构约束 | — | BLOCKED（边界） |
| `codex-ipc` 管道 / UI 注入 / 改会话数据库 | — | — | — | — | — | — | — | — | — | 违反安全边界 | — | 无 | 不采用 |
| 现有 Desktop Direct 路由切换（需重启/新线程） | — | — | — | — | 否 | 是（手动） | 否 | 是 | 是 | 无 | 已在 main | — | 不满足自动切换 |

## 2. 已验证的 Git 基线与 Codex 版本

| 项 | 值 | 核实方式 |
|---|---|---|
| `origin/main` | `13ef69e808eaecfe2a46b65f756fa78d8d0e6597`（Merge PR #104） | `git fetch` + `git rev-parse` |
| `main` CI | Development Gate #323 success（run 38231158053） | `gh run list` |
| 研究分支 / worktree | `research/m1-chatgpt-quota-failover`，`%USERPROFILE%\cmm-wt\m1-quota` | ACL 核验：仅当前用户、SYSTEM、Administrators 有写权限 |
| 实验目录 | `%USERPROFILE%\cmm-wt\m1-lab`（仓库外，同样 ACL 核验） | 实验脚本与产物不提交 |
| Codex CLI（npm） | `codex-cli 0.154.0` | `codex --version` |
| Codex Desktop | MSIX `OpenAI.Codex 26.1007.2314.0`；内置 `codex-cli 0.162.0-alpha.17.2` | `Get-AppxPackage`、内置 `codex.exe --version` |
| 运行中的 `codex.exe`（PID 18632） | **Desktop 自己的 app-server**（`app-server --analytics-default-enabled`，stdio） | 只读进程命令行；本研究从未连接、停止或修改它 |
| 官方源码 | `openai/codex` 标签 `rust-v0.162.0-alpha.17.2`（`f04373e`）、`rust-v0.154.0`（`36eab01`） | `gh api` 只读下载 |
| 协议 Schema | 两个二进制各自 `codex app-server generate-json-schema`（305 / 317 个文件） | 隔离 `CODEX_HOME` |

与历史研究（`HOT_SWITCH_FEASIBILITY_GATE.md`，Desktop 内置 0.153.4、npm 0.149.1/0.154.0）相比，Desktop 已升级到 0.162 alpha，因此本研究对关键限制做了复核（§6）。

## 3. 现有代码能力复用清单（研究 E）

| 组件（`main` 上已存在） | 对 G-1…G-6 的作用 | 判定 |
|---|---|---|
| Direct Mode（ChatGPT 官方账户 profile、`launch-controller-model.ps1`） | G-1 默认官方模型 | **已存在可直接复用** |
| Git handoff（`collect-handoff.ps1` / `resume-handoff.ps1`） | 跨会话转交时保护工作区 | 已存在可直接复用（只保护 Git，不保留对话上下文） |
| 已批准模型注册表（`approved-models.json`、`model-catalog.json`） | 备用模型候选来源（只含已批准） | 已有部分能力：需要“备用顺序”这一新字段/配置 |
| Codex CLI Adapter（LR-12） | 让 CLI 指向 Router | 已有部分能力：其 SUPPORTED 证据来自 `fake-router.ps1`，**不是真实 Router 解析器**（§5.5） |
| Codex Desktop Adapter（LR-13） / Desktop Direct 第三方路由 | Desktop 改路由需重启/新线程 | 存在结构性障碍：不能对运行中的 Desktop 线程自动切换 |
| Local Router（LR-0…LR-14） | 备用模型执行层 | **待确认的兼容性阻断风险**：本研究的 Codex 0.162 请求样本被现有 fail-closed 解析规则拒绝（§5.5）；这是安全设计按预期生效，不是缺陷，但意味着 Router 能否承接真实 Codex 流量需要单独确认 |
| HS-1B 线程模型选择（#89，默认关闭） | 线程级、generation/CAS、手动优先 | 已有部分能力：仅 Router 内；不感知 ChatGPT 线程 |
| HS-1C（Draft #88，未进入 main） | 粘性切换、不切回、手动后重新武装、已耗尽跳过 | 已有部分能力（未合并）：只覆盖 Router 内第三方 Provider；其文档明确 ChatGPT 账户耗尽需要单独“官方耗尽信号桥” |
| V4 Visual Console / LR-14 控制面 | 状态展示 | 需要新增接口：额度切换状态、原因、基础历史 |
| Host 生命周期（PR10B）、安装/卸载/回滚（PR6–PR9） | 与本功能无直接依赖 | 无冲突；托管会话网关若作为常驻进程，需复用 PR10A/10B 的生命周期与 ACL 规则 |

### 3.1 备用模型选择（研究 D）

| 问题 | 现有组件 | 判定 |
|---|---|---|
| 用户批准的备用候选列表 | Direct：`approved-models.json` / `model-catalog.json`（只含显式批准模型）；Router：路由的 `fallback_route_ids`（HS-1C） | 部分具备：缺少“ChatGPT 订阅线程的备用顺序”这一配置，需要新增，且只能引用已批准模型 |
| 候选可用性判断 | HS-1C `QuotaAvailabilityTracker`（AVAILABLE / UNKNOWN / EXHAUSTED，只由真实请求结果更新） | 可复用语义；**不做付费探测**；不可证明时保持 UNKNOWN，不虚构可用 |
| 明确耗尽后的选择顺序 | HS-1C：跳过 EXHAUSTED，AVAILABLE 先于 UNKNOWN，配置顺序为次序 | 可复用 |
| 多个备用先后耗尽 | HS-1C 单遍接力（Router 内） | 可复用；跨 Provider 场景需在 Manager 编排层重新实现同一语义 |
| 全部不可用时退出 | HS-1C 全部失败后返回原始错误 | **需新增**：明确的“全部备用不可用”状态、原因与记录（G-6） |
| 手动与自动并发 | HS-1B/HS-1C generation CAS（Router 内） | Manager 编排层需要对等的 CAS；TUI 手动切换事件未验证 |
| 不自动切回（G-5） | HS-1C 规则 6 | 可复用 |
| V4 状态与切换记录 | LR-14 控制面无此字段 | 需新增接口 |
| 不新增 Provider、不付费探测 | 现有审批流程 | 已满足；本研究未新增任何 Provider |

## 4. ChatGPT 订阅额度信号研究（研究 A）

### 4.1 官方信号来源（A）

1. **结构化错误**：app-server 通知 `error` 与 `turn/completed` 的 `turn.error.codexErrorInfo`。枚举（两个版本均有）包含 `usageLimitExceeded`、`rateLimitExceeded`、`serverOverloaded`、`internalServerError`、`unauthorized`、`badRequest`、`other`，以及带 `httpStatusCode` 的 `httpConnectionFailed`、`responseStreamConnectionFailed`、`responseStreamDisconnected`、`responseTooManyFailedAttempts`。0.162 另增 `flexUnavailable`、`tooManyDenials`。
2. **账户额度快照**：通知 `account/rateLimits/updated` 与请求 `account/rateLimits/read`。`RateLimitSnapshot` 含 `primary/secondary.usedPercent`、`resetsAt`、`windowDurationMins`、`planType`、`rateLimitReachedType`（`rate_limit_reached`、`workspace_*_usage_limit_reached`、`workspace_*_credits_depleted`）、`credits`；`GetAccountRateLimitsResponse` 另有 `ordinaryUsageAllowed`（schema 描述：后端针对当前账户校验的“普通内含用量”许可；null 表示不可用，客户端不得根据百分比或重置时间推断恢复）与 `rateLimitsByLimitId`。
3. **官方源码中的判定**（`codex-api/src/api_bridge.rs`）：HTTP 429 且响应体 `error.type == "usage_limit_reached"` → `UsageLimitReached`（携带 `plan_type`、`resets_at`、由 `x-codex-*` 响应头解析的额度快照与 `rate_limit_reached_type`）；`usage_not_included` → `UsageNotIncluded`；其他 429 → 重试后 `RetryLimit`。以上两个标签一致。**差异**：`rust-v0.162.0-alpha.17.2` 另有 `insufficient_quota` 及 `credit_balance_exhausted`、`organization_spend_limit_exceeded` 等 → `QuotaExceeded` 的分支；`rust-v0.154.0` 没有该分支（与 §4.2 实验结果一致）。
4. **关键合并**（`protocol/src/error.rs` `to_codex_protocol_error`）：`UsageLimitReached`、`QuotaExceeded`、`UsageNotIncluded` **三者都映射为同一个外部值 `usageLimitExceeded`**，且都不重试。`UsageLimitReached` 会额外调用 `update_rate_limits`，从而发出 `account/rateLimits/updated`。
5. **判定不校验来源**：源码按响应体与响应头判定，不校验是否来自 ChatGPT 后端。实验（§9 E1）中自定义 fake Provider 发出相同 429 体即得到完全相同的信号。

### 4.2 七类情况能否区分（B：E1，两个版本）

| 情况 | 0.162.0-alpha.17.2 观察 | 0.154.0 观察 | 可明确分类？ | 误判风险 |
|---|---|---|---|---|
| 1 订阅额度耗尽（`usage_limit_reached` + 额度头） | `usageLimitExceeded`，`willRetry=false`，1 次上游请求；同轮 `account/rateLimits/updated`：primary 100%、`reachedType=rate_limit_reached` | 相同 | **条件可分**：需同时满足 Provider 为官方 `openai` + 账户为 ChatGPT 登录 + 同轮额度快照显示耗尽 | 无额度头时快照为空（`m-usage-nohdr`），只能判 UNKNOWN；真实后端是否总带头 **NOT VERIFIED（D）** |
| 2 API Key 额度耗尽（`insufficient_quota`） | `usageLimitExceeded`，无额度快照 | **`responseTooManyFailedAttempts{429}`** | 仅凭错误码不可分；**两个版本结果不同** | 高：版本漂移；必须与 Provider 身份绑定并按版本表判定 |
| 3 一般速率限制（普通 429） | `responseTooManyFailedAttempts{429}` | 相同 | 可分 | 低 |
| 4 网络故障（连接拒绝） | 持续 `responseStreamDisconnected{null}`，`willRetry=true`，>120 s 未结束（需 `turn/interrupt` 清理） | 相同 | 可分（不是耗尽） | 低；但会长时间挂起 |
| 5 Provider 服务器错误（500 / 503 overloaded） | `internalServerError` / `serverOverloaded` | 相同 | 可分 | 低 |
| 6 身份验证失败（401） | `httpConnectionFailed{401}` | **`other`** | 可分为“非耗尽”；具体类型随版本变化 | 中（版本漂移） |
| 7 模型暂时不可用（404 model_not_found） | `httpConnectionFailed{404}` | **`other`** | 同上 | 中 |
| 附：套餐不含 Codex（`usage_not_included`） | `usageLimitExceeded`，无额度快照 | 相同 | 与 1 共用错误码；靠“无额度快照”区分 | 中 |

### 4.3 建议的订阅耗尽判定规则（设计，未实现）

只有**全部**满足才判定为“ChatGPT 订阅额度耗尽”，否则为“非耗尽”或 UNKNOWN（UNKNOWN 不切换）：

1. 该轮 `codexErrorInfo == usageLimitExceeded` 且 `willRetry == false`；
2. 该线程 `ThreadSettings.modelProvider == "openai"`（内置官方 Provider），且 `account/read` 显示 ChatGPT 登录方式（不是 API Key）；
3. 同一轮内收到 `account/rateLimits/updated`，且 `rateLimitReachedType` 非空或某窗口 `usedPercent >= 100`；
4. （可选，需老板批准，见 §15）在第 1–3 条成立后，**事件触发**一次 `account/rateLimits/read`，以 `ordinaryUsageAllowed == false` 作为后端确认。这是免费读取、非轮询、非推理，但属于“主动读取额度状态”，按 PRODUCT_VISION 非目标需要老板单独批准。
5. 分类表按 Codex 版本固定（0.154 / 0.162 已有差异），未知版本一律 UNKNOWN。

### 4.4 可观察性（谁能拿到信号）

| 通道 | 结构化耗尽信号 | 证据 |
|---|---|---|
| app-server 协议（stdio 或 `--listen ws://`） | 有 | A + B |
| `codex exec --json` | **无**：只有 `turn.failed {error:{message}}` 纯文本 | A（`exec/src/exec_events.rs`） |
| 交互式 TUI（非 `--remote`） | 外部进程无法获得（TUI 进程内消费） | A |
| Desktop | 只在 Desktop 自己的 app-server 与 UI 内；外部无通道 | A + B（§6） |
| Local Router | **看不到**：ChatGPT 订阅流量为 `DIRECT_ONLY`，不经过 Router | 架构约束 |
| 会话 rollout 文件 | 不使用：属于私人会话内容，本研究禁止读取 | — |

## 5. Codex CLI 自动切换研究（研究 B）

### 5.1 候选路径

| 路径 | 说明 |
|---|---|
| **C1 Manager 托管 app-server + `codex --remote`** | Manager 以用户的 `CODEX_HOME` 启动 `codex app-server --listen ws://127.0.0.1:<port> --ws-auth capability-token`；CLI TUI 用 `--remote` 连接；Manager 作为第二个客户端订阅线程、接收信号并执行切换。 |
| C2 Manager 启动非交互 `codex exec` | 只有文本错误，无法可靠区分订阅/API 额度。 |
| C3 官方 daemon + TUI 自动附着 | 官方 README 称 TUI 会自动附着已发现的 daemon；但 daemon 需要官方 standalone 安装（本机 npm 与 Desktop 内置二进制均报错拒绝）。 |
| C4 现有“新会话 + Git handoff” | 只保护工作区，不保留对话上下文；可作为降级路径参考，但不是自动接续。 |

### 5.2 C1 实验结果（B：E3/E3b，两个版本一致）

- 未带 token、错误 token 的 WebSocket 握手均返回 **HTTP 401**；正确 token 返回 101。服务端只绑定 localhost。
- Manager 客户端对另一客户端已加载的线程调用 `thread/resume` 即完成订阅，并**实时收到**对方该轮的 `error = usageLimitExceeded` 与 `account/rateLimits/updated`（100%、`rate_limit_reached`）。
- Manager 对该**已加载**线程调用 `thread/resume(modelProvider, model)`：**被忽略**（返回仍是原 Provider/模型）。
- Manager 对该线程调用 `turn/start(model=同 Provider 的另一模型, input=…)`：**生效**，原客户端可见该轮；原客户端随后的普通轮次**粘性**使用新模型。→ **同 Provider 内可以原线程切换**，但 `turn/start` 必须携带输入。
- Manager 调用 `thread/fork(modelProvider=备用, model=…)`：**生效**，得到**新线程 id**，历史（含失败轮的用户输入）保留；原客户端仍停留在原线程。

### 5.3 跨 Provider 切换（B：E2/E2b/E2c/E4）

ChatGPT 订阅模型的 Provider 是 `openai`；已批准的第三方备用模型在其他 Provider（Direct 第三方或 `mm_local_router`）。`turn/start` 没有 `modelProvider` 参数（A），因此**跨 Provider 不能原线程切换**：

| 方式 | 结果（两个版本一致） |
|---|---|
| 已加载线程 `thread/resume(modelProvider, model)` | 忽略 |
| 同进程 `thread/unsubscribe` → `thread/resume(...)`，等待 0 / 3 / 12 秒 | 忽略（未见线程卸载通知）。**与历史研究 §15.4 A5 的 PASS 结论不一致**，原因未查明；本研究以当前结果为准，不推断 |
| **新 app-server 进程**对未加载线程 `thread/resume(modelProvider, model)` | **生效**；同一线程 id；历史保留；后续轮次粘性 |
| `thread/fork(modelProvider, model)` | **生效**；新线程 id；历史保留 |
| 失败轮的用户输入 | 保留在线程历史中，备用模型可见 |
| 先前轮次的 `reasoning` 项（含 `encrypted_content`） | **跨 Provider 后原样回放给备用 Provider**（fork：2 项；新进程 resume：1 项），并附带 `include:["reasoning.encrypted_content"]`、`store:false` |

### 5.4 任务安全

- 耗尽在请求阶段返回（429），该次请求无模型输出；但同一轮内若已执行过工具调用、之后的采样请求才耗尽，则文件写入等副作用已经发生。**自动把失败输入重新提交给备用模型可能重复执行操作**。是否会出现“轮中耗尽”**NOT VERIFIED**（需 D）。
- 本研究不建议自动重放失败输入；是否允许、以何种提示继续，属于老板决策（§15）。
- 手动优先（G-4）：建议在检测到耗尽时记录线程当前（Provider, 模型, generation），切换前做 compare-and-set；用户在此期间的任何手动选择都使自动切换作废。真实 TUI 中 `/model` 在 remote 模式下如何体现为协议事件 **NOT VERIFIED**。

### 5.5 关键发现：Codex 0.162 请求样本被 Local Router 解析器拒绝——待确认的兼容性阻断风险（B，样本范围内）

**样本范围**：本研究只有 **2 个**请求样本，均由 Desktop 内置 `codex-cli 0.162.0-alpha.17.2` 在隔离 `CODEX_HOME`（默认配置、无 MCP、无插件）下发往 fake Provider：样本 S1 = 新线程首个请求；样本 S2 = 跨 Provider fork 后的首个请求。被测解析器是 `main`（`13ef69e`）上的 `local-router/src/Router.ClientAdapters.Responses/ResponsesRequestParser.cs`（最后修改提交 `7d40942`，本 PR 未改动），通过 `ResponsesRequestParser.TryParse` 只读调用。

**在这两个样本中，拒绝发生在三个位置**（证据与解析器代码对应）：

| 位置 | 样本中的实际内容 | 解析器结果 | 对应代码（`ResponsesRequestParser.cs`） |
|---|---|---|---|
| 1 `namespace` 工具 | `tools[4]` = `{type:"namespace", name:"multi_agent_v1", tools:[5 个子工具]}` | `unsupported_capability` @ `tools[4].type`，诊断类 `namespace` | 第 1278 行：非 `function` 类型（除 `apply_patch` 自定义工具外）进入拒绝分支；第 1295 行 `SafeToolTypeClassifier.Classify`；第 1309 行 `UnsupportedCapabilityAtClassified` |
| 2 reasoning 历史项 | S2 的 `input` 中回放的 `{type:"reasoning", id, summary, content, encrypted_content}` | `unsupported_parameter` @ `input[i].content` | 第 405 行分派到 `ParseReasoningItem`（第 1086 行）；只接受 `type/id/summary`，其他键在第 1127 行返回 `UnsupportedParameter` |
| 3 `include` 等根字段 | `include:["reasoning.encrypted_content"]`、`prompt_cache_key`、`client_metadata`、`parallel_tool_calls` | 各自单独加回时分别得到 `unsupported_parameter` @ 该字段名 | 第 25–40 行 `SupportedRootFields` 允许清单不含这些字段；第 256–259 行“未知字段默认拒绝” |

**隔离与边界对照**（同一样本，逐项加回；E5b）：

| 变体 | S1 | S2 |
|---|---|---|
| 原样 | 拒绝：位置 1 | 拒绝：位置 2 |
| 去掉 tools、tool_choice、parallel_tool_calls 与 reasoning 项，保留其余根字段 | 拒绝：`include` | 拒绝：`include` |
| 再去掉 `include`、`prompt_cache_key`、`client_metadata` | **接受** | **接受** |
| 在“接受”基线上只加回 `include` / `prompt_cache_key` / `client_metadata` / `parallel_tool_calls` | 各自单独拒绝 | 各自单独拒绝 |
| 只加回 `tool_choice` | 接受 | 接受 |
| 只加回 tools 但去掉 `namespace` 项 | 拒绝：`tools[7].type`（诊断类 `web_search`） | 同左 |
| 只加回一个 reasoning 项（原样，含 `content`、`encrypted_content`） | 样本无该项 | 拒绝：`input[i].content` |
| 只加回一个 reasoning 项，裁剪为 `type/id/summary` | — | **接受** |

**结论边界**：

- 只能说：**这 2 个样本**在上述位置被拒绝；在样本中，除 `namespace` 外，`web_search` 工具同样会被拒绝。**不能**推断“所有 Codex 0.162 请求都会失败”——其他配置（例如关闭多代理或网络搜索工具、不同 reasoning 设置、MCP、其他 Codex 版本）未被采样。
- 这些拒绝是 Router **按设计 fail-closed**：未知字段与不能保证语义的工具/历史项一律拒绝，以避免静默语义丢失。**本研究不把这一安全设计视为缺陷**，也不建议删除字段校验、弱化断言、修改 Router 生产代码或改变 Direct Mode。
- 影响：把 Router 作为真实 Codex 流量的执行层（V1-07 CLI Router 集成、V1-10 HS-1C、V1-11 跨 Provider 备用）存在**待确认的兼容性阻断风险**。LR-12 兼容矩阵中的 SUPPORTED 证据来自 `tests/fixtures/local-router/codex-cli/fake-router.ps1`，未经过真实解析器，因此不覆盖此风险。是否更新 PROJECT_STATUS、是否立项做“兼容策略（含显式 semantic-loss 规则）”，由项目经理与老板决定。

## 6. Codex Desktop 自动切换研究（研究 C）

### 6.1 复核历史限制（Desktop 26.1007.2314.0 / 内置 0.162.0-alpha.17.2）

| 历史结论 | 当前复核 | 证据 |
|---|---|---|
| `turn/start(model=…)` 可覆盖后续模型（独立 app-server） | 仍成立，且仅限同 Provider | B（E3b） |
| 已加载线程 `thread/resume(model)` 被忽略 | 仍成立（含跨 Provider） | B |
| 无法接管运行中 Desktop 的 app-server | 仍成立：Desktop app-server 命令行为 stdio（无 `--listen`）；`~/.codex/app-server-control` 不存在；Codex 相关命名管道仅 `codex-ipc`（未公开，未打开）、`codex-browser-use-*`、沙箱管道 | A + B（只读进程/管道名检查） |
| daemon 仅 Unix | **已变化**：0.162 有 `daemon bootstrap/start/enable-remote-control`，官方 README 称支持 Windows；但需要官方 standalone 安装，本机两个二进制均拒绝启动；Desktop 未使用 daemon | A + B |
| 独立协议成功 ≠ Desktop UI 成功 | 仍成立；本研究未接触任何 Desktop 线程 | — |

### 6.2 Desktop 结论

- **自动检测**：ChatGPT 订阅耗尽信号只存在于 Desktop 私有的 app-server 连接内，外部 Manager 拿不到；Router 也看不到（`DIRECT_ONLY`）。→ BLOCKED。
- **自动切换**：即使拿到信号，跨 Provider 也需要卸载/新进程 resume 或 fork，而 Desktop 持有线程且无外部控制通道。→ BLOCKED。
- **范围**：仅针对上述 Desktop 版本、Windows、本地运行中的 Desktop。官方 daemon/remote-control 能否让本地 Desktop 连接 Manager 托管的 app-server：**UNKNOWN**（需要官方文档明确或经批准安装 standalone 后做 C 级实验）。

## 7. 候选技术方案比较

| 方案 | 覆盖 | 自动触发 | 保留上下文 | 主要障碍 | 结论 |
|---|---|---|---|---|---|
| P1 Manager 托管会话网关（CLI，C1） | CLI | 是（B） | 同 Provider：原线程；跨 Provider：fork/新进程 resume（B） | TUI 重新附着未验证；Router 兼容性（§5.5）；新运行形态需批准 | **推荐研究继续（PARTIAL）** |
| P2 同 Provider 内备用（ChatGPT 订阅内其他模型） | CLI | 是（B） | 原线程（B） | 是否存在按模型独立的额度桶（`rateLimitsByLimitId` 暗示，但 **NOT VERIFIED**）；是否算“备用模型”需老板定义 | 候选（UNKNOWN） |
| P3 官方 daemon + TUI 自动附着 | CLI（Desktop 未知） | 是（推测） | 同 P1 | 需 standalone 安装；实验性接口 | UNKNOWN |
| P4 Router 侧检测 | — | — | — | ChatGPT 流量不经 Router；代理账户凭据被禁止 | **不采用**（违反边界） |
| P5 读取 rollout / 抓取 UI | — | — | — | 读取私人会话 / UI 注入，被禁止 | **不采用** |
| P6 用 OpenAI API Key 代替订阅 | — | — | — | 不是同一额度来源，不满足 G-1…G-5 | **不采用** |
| P7 “提示 + 一键切换” | CLI/Desktop | 否 | 视实现 | 不是自动切换 | 只能经老板批准作为降级方案 |

## 8. 失败模式与安全分析

| 失败模式 | 风险 | 缓解（设计） |
|---|---|---|
| 把 API Key 额度或“套餐不含”误判为订阅耗尽 | 错误切换 | §4.3 多条件判定 + Provider/账户身份绑定 + 版本表；不满足即 UNKNOWN、不切换 |
| 第三方 Provider 伪造 `usage_limit_reached` | 错误切换 | 只接受 `modelProvider == "openai"` 线程的信号 |
| 无额度头导致快照为空 | 漏判（不切换） | 保守：UNKNOWN 不切换；可选事件触发 `ordinaryUsageAllowed` 确认（需批准） |
| 版本升级改变错误映射 | 误判 | 分类表按版本固定；未知版本 fail-closed |
| 轮中耗尽后自动重放输入 | 重复执行工具/写文件 | 默认不重放；需老板决策 |
| 加密 reasoning 回放给第三方 | 备用请求被拒或语义丢失 | 需要明确的“跨 Provider 历史处理策略”接口；禁止静默丢弃（AGENTS / Router 的 semantic-loss 规则） |
| 全部备用不可用 | 无限重试 / 擅自选择 | 有界单遍、只用已批准列表；明确失败状态 + 历史记录（G-6） |
| 网络故障长时间挂起 | 用户以为在切换 | 网络故障不触发切换；只显示状态 |
| 托管网关被其他本地进程连接 | 会话被劫持 | loopback + capability token（已验证 401）；token 文件 ACL；遵守 PR10A/10B 的目录与能力文件规则 |
| 手动与自动并发 | 覆盖用户选择 | generation CAS；手动永远优先；不自动切回（G-5） |

## 9. 免费隔离实验与可复现证据

所有实验：隔离 `CODEX_HOME`（`m1-lab\home-*`）；fake Provider 只绑定 `127.0.0.1` 随机端口；合成 token；未设置任何真实 API Key（启动子进程前移除所有 `*_API_KEY` 环境变量）；未读取 `auth.json`、未访问 `~/.codex`、未连接 Desktop 的 app-server；**付费调用 0 次**。实验脚本保存在仓库外 `%USERPROFILE%\cmm-wt\m1-lab`，按规则不提交。

| 编号 | 脚本 | 内容 | 二进制 |
|---|---|---|---|
| E1 | `e1_signals.py` | 11 种上游结果的分类、`willRetry`、额度通知、上游请求次数 | 0.162、0.154 |
| E2 | `e2_provider_switch.py` | 耗尽后已加载 resume / unsubscribe+resume / fork | 0.162、0.154 |
| E2b | `e2b_resume_variants.py` | 隔离变量：同 Provider 仅换模型、跨 Provider、新进程 resume、fork | 0.162、0.154 |
| E2c | `e2c_unsub_timing.py` | unsubscribe 后等待 0/3/12 秒再 resume | 0.162、0.154 |
| E3/E3b | `e3_multiclient.py` | `--listen ws://` + capability token；双客户端观察与切换 | 0.162、0.154 |
| E4 | `e4_reasoning_replay.py` | 跨 Provider 后是否回放加密 reasoning | 0.162、0.154 |
| E5 | `e5_capture.py` + `probe/` | 捕获真实请求体；只读调用 Router `TryParse` | 0.162 + 本 worktree 构建的 Router |
| S | `generate-json-schema`、`gh api` 源码 | 协议与源码证据 | 0.162、0.154 |

复现要点：
1. 在 ACL 合规的目录准备 `lab.py`（fake Provider + stdio JSON-RPC 驱动）与上述脚本；
2. `python e1_signals.py desk0162 cli0154`（约 5 分钟，网络故障用例各约 140 秒）；
3. 其余脚本同理；E5 需要先 `dotnet build local-router/src/Router.ClientAdapters.Responses -c Release`。

过程披露：E2 首次运行中 fork 步骤误写为 `fake_a`，该步结果作废，已由 E2b 的 V4 重做；E3b 首次运行时脚本把 Manager 轮次的完成事件误当作原客户端的完成事件，修正后重跑，结论以修正后为准。

**复跑与可复核性**：2026-10-12 19:37–19:45（+08:00）在同一机器上对 E1、E2b、E2c、E3/E3b、E4、E5 全部重跑一次，并新增 E5b 逐字段对照；与首轮相比，E1–E4 的全部结构化结论逐行一致。完整输入、步骤与观察结果见**附录 A**。由于实验脚本按任务规则不提交仓库，**所有 B 级实验结论均为“开发者报告，待独立复现”**；A 级证据（官方 Schema、官方源码、本仓库代码）可按附录中的版本与路径独立核对。

## 10. 对原有架构的影响

- **Direct Mode**：默认行为不变；G-1 已满足。
- **Router**：不需要推倒，现有 fail-closed 校验保持不变；若要作为真实 Codex 流量的备用执行层，需先确认 §5.5 的兼容性阻断风险在真实配置中的范围，再由老板决定是否立项设计显式兼容策略（例如加密 reasoning 回放的处理，属于安全语义变更，需单独审查）。本研究不提出任何删除校验或弱化断言的方案。
- **HS-1B / HS-1C**：其粘性、不切回、手动优先、重新武装、已耗尽跳过可复用于“选择哪个备用”；但触发源需要从 Manager 的订阅耗尽信号进入，且 G-6 需要新增“全部备用不可用”状态与记录。
- **新增运行形态**：CLI 自动切换需要 opt-in 的“Manager 托管会话网关”，用户的 CLI 通过它连接；这改变用户启动 CLI 的方式，需老板批准。
- **V4**：需要新增额度切换状态、原因与基础历史展示。
- **安装/生命周期**：网关若常驻，应复用 PR10A/PR10B 的启动门、ACL 与能力文件规则。

## 11. 推荐方案与备选方案

**推荐（继续研究，不施工）：** P1 Manager 托管会话网关（仅 CLI）。它**只是候选方案**，未经老板批准不得施工；按以下顺序补证据后再由老板决定 V1-11 范围：
1. 免费 C 级验证：真实 `codex --remote` TUI 连接托管 app-server（隔离 `CODEX_HOME` + fake Provider），确认 TUI 可正常工作、Manager 可观察、TUI 能否被引导到 fork 后的线程；
2. 对 §5.5 的待确认兼容性阻断风险，先扩充真实配置下的请求样本确认范围，再由老板决定是否立项（独立于 M1，见 §14 S1）；
3. 经批准的 D 级验证（§12）。

**备选：** P2 同 Provider 内备用（需先证明独立额度桶）；P3 官方 daemon（需 standalone 安装）。
**降级（仅老板批准后）：** P7 “提示 + 一键切换”。
**Desktop：** 当前版本 BLOCKED；建议跟踪官方 daemon/remote-control 对 Desktop 的支持，不做任何注入或私有通道尝试。

## 12. 尚未验证的关键问题（NOT VERIFIED / UNKNOWN）

| # | 问题 | 需要的证据 | 最小测试方案（需老板批准后执行） |
|---|---|---|---|
| U1 | 真实 ChatGPT 后端在订阅耗尽时是否总返回 `usage_limit_reached` + `x-codex-*` 额度头 | D | 不故意耗尽额度；在用户自然达到上限时，于托管网关中被动记录结构化信号（只记录分类字段，不记录内容） |
| U2 | 真实账户 `account/read` / `account/rateLimits/read` 字段（authMode、planType、`ordinaryUsageAllowed`）实际取值 | C | 用户批准后，对真实 `CODEX_HOME` 只读调用一次这两个方法（无推理、不读 `auth.json`，由 Codex 自身处理凭据） |
| U3 | 真实 TUI 以 `--remote` 连接托管网关是否完整可用，能否切到 fork 线程 | C | 隔离 `CODEX_HOME` + fake Provider，关闭更新检查，人工观察 |
| U4 | 第三方备用 Provider 是否接受回放的加密 reasoning | C/D（付费） | 每个已批准备用 Provider 各 1 次最小请求，需逐个批准 |
| U5 | 订阅内是否存在按模型独立的额度桶 | D | 被动观察 `rateLimitsByLimitId` |
| U6 | 同进程 unsubscribe→resume 与历史 §15.4 结论不一致的原因 | B | 对照历史脚本参数重跑 |
| U7 | 官方 daemon / remote-control 能否让本地 Desktop 或 TUI 附着 | A/C | 查官方文档；或经批准安装 standalone 后在隔离环境实验 |
| U8 | 轮中耗尽（工具执行后）是否发生、如何呈现 | D | 同 U1，被动记录 |
| U9 | remote 模式下用户 `/model` 手动切换在协议中的表现 | C | 与 U3 一起 |

## 13. V1-11 技术可行性建议

- V1-11 保持在 V1 决策清单中（本研究不建议移出，也无权移出）。
- 技术判断：**CLI = PARTIAL（B）**，可在补齐 U2/U3、并确认 §5.5 风险范围与处理方式后，再由老板决定是否进入工程切片；**Desktop = BLOCKED（当前版本）**。
- 若老板希望 V1 包含 V1-11，可选的范围表述（供老板选择，不是本研究的决定）：
  - (a) V1-11 仅覆盖 CLI 的托管会话形态，Desktop 记为已知限制；
  - (b) V1-11 等待 U1–U4 证据后再决定；
  - (c) 经老板批准采用降级方案 P7。

## 14. 后续最小工程切片建议（仅建议，均需单独批准，未实现）

| 切片 | 内容 | 依赖 |
|---|---|---|
| S0 | 研究补证：U3（免费 C 级）、U6 | 无 |
| S1 | 先扩充真实配置下的请求样本，确认 §5.5 风险范围；若老板批准立项，再设计显式兼容策略（Codex 根字段、`namespace`/`web_search` 工具、reasoning 回放；显式 semantic-loss 记录；不删除校验、不弱化断言） | 安全审查 + 老板批准 |
| S2 | 订阅耗尽分类器（纯函数 + 版本表 + E1 形态夹具） | 无 |
| S3 | Manager 托管会话网关原型：**只观察、不切换** | S2、PR10A/10B 规则 |
| S4 | 切换编排：fork/新进程 resume + 备用选择（复用 HS-1C 语义）+ 手动优先 CAS | S1、S3、U3 |
| S5 | G-6 “全部备用不可用”状态 + 基础切换历史；V4 展示 | S4 |

## 15. 需要老板决策的事项

1. 是否接受“Manager 托管会话网关”作为 CLI 的新运行形态（用户通过 Manager 启动或连接 CLI）？
2. 是否批准 U2（对真实账户只读调用两个账户接口）与 U3（免费 C 级 TUI 实验）？
3. 是否批准事件触发的 `account/rateLimits/read`（`ordinaryUsageAllowed` 确认）？它是免费读取，但属于 PRODUCT_VISION 非目标中的“主动查询额度”，需要明确批准。
4. 订阅耗尽后，是否允许把失败轮的用户输入自动提交给备用模型（存在重复执行风险），还是只切换模型、由用户继续？
5. ChatGPT 订阅内的其他模型（若有独立额度桶）是否算“已批准备用模型”？
6. Desktop 在当前版本 BLOCKED：V1-11 是否只覆盖 CLI，还是等待官方能力？
7. §5.5 的待确认兼容性阻断风险（涉及 V1-07、V1-10、V1-11）是否先做真实配置下的样本扩充确认，再决定是否立项？
8. 是否批准任何付费验证（U4）或环境变更（安装 standalone Codex，U7）？

## 附录 A — 可复核证据（脱敏）

本附录只包含合成数据：合成模型名（`m-*`）、合成 Provider（`fake_a`、`fake_b`、`fake_down`）、合成标记（`MARK_*`）与合成 token。不包含任何真实会话、凭据、账户数据、Codex 系统指令或真实请求正文。

### A.0 证据分类与可复核状态

| 类别 | 内容 | 可复核状态 |
|---|---|---|
| A 官方协议 | 两个二进制 `codex app-server generate-json-schema` 生成的 Schema | 可独立复核：用同版本二进制重新生成即可 |
| A 官方源码 | `openai/codex` 标签 `rust-v0.154.0`（`36eab01`）、`rust-v0.162.0-alpha.17.2`（`f04373e`），见 A.1 | 可独立复核：固定标签 + 行号 |
| A 本仓库代码 | `ResponsesRequestParser.cs`（`main` `13ef69e`，文件最后修改 `7d40942`）；Draft #88 分支代码 | 可独立复核 |
| B 隔离实验（模拟） | E1–E5：真实 Codex 二进制 + **模拟**上游（fake Provider）+ 隔离 `CODEX_HOME` | **开发者报告，待独立复现**（脚本未入库；本附录给出足以重建的输入与步骤） |
| C 真实集成 | 无 | 未执行 |
| D 真实订阅耗尽 | 无 | 未执行 |

**模拟与实际的区分**：E1–E5 中“Codex 客户端行为”（分类、重试、通知、线程/Provider 处理、请求形状）来自**真实的官方 Codex 二进制**；“上游返回”（429/500/额度头/reasoning 项）全部是**模拟**的；E3 中的“TUI”由第二个 JSON-RPC 客户端**模拟**，不是真实 TUI。E5b 的“Router 判定”来自**真实的本仓库解析器代码**，输入是 E5 在模拟上游环境下捕获的真实 Codex 请求形状。

### A.1 版本与官方位置

| 项 | 值 |
|---|---|
| Desktop 内置二进制 | `%LOCALAPPDATA%\OpenAI\Codex\bin\2e5e00daee91c61d\codex.exe` → `codex-cli 0.162.0-alpha.17.2`（MSIX `OpenAI.Codex 26.1007.2314.0`） |
| npm 二进制 | `%APPDATA%\npm\node_modules\@openai\codex\node_modules\@openai\codex-win32-x64\vendor\x86_64-pc-windows-msvc\bin\codex.exe` → `codex-cli 0.154.0` |
| Schema 生成 | 设置隔离 `CODEX_HOME` 后执行 `codex app-server generate-json-schema --out <dir>`；0.154 = 305 个文件，0.162 = 317 个文件 |
| Schema 关键文件 | `v2/ErrorNotification.json`（`CodexErrorInfo`、`TurnError`）、`v2/GetAccountRateLimitsResponse.json`（`RateLimitSnapshot`、`ordinaryUsageAllowed`）、`v2/AccountRateLimitsUpdatedNotification.json`、`v2/TurnStartParams.json`、`v2/ThreadResumeParams.json`、`v2/ThreadForkParams.json`、`ClientRequest.json`、`ServerNotification.json` |

官方源码位置（固定标签，URL 形式 `https://github.com/openai/codex/blob/<标签>/<路径>#L<起>-L<止>`）：

| 证据 | 0.162.0-alpha.17.2 | 0.154.0 |
|---|---|---|
| 429 分类（`usage_limit_reached` / `usage_not_included` / `insufficient_quota`） | `codex-rs/codex-api/src/api_bridge.rs` L181–L240（`insufficient_quota` 分支 L221–L233） | 同文件：`usage_limit_reached` L135、`usage_not_included` L160；**无** `insufficient_quota` 分支 |
| 内部错误 → `codexErrorInfo`（三者合并为 `UsageLimitExceeded`） | `codex-rs/protocol/src/error.rs` L473–L511（合并在 L478–L480） | 同文件 L431–L463（合并在 L436–L438） |
| 不重试 | 同文件 `retry_delay` L397–L424（`UsageLimitReached`、`QuotaExceeded` 返回 `None`） | 未逐行核对 |
| 耗尽时更新额度快照 | `codex-rs/core/src/session/turn.rs` L1700–L1705 | 未下载核对 |
| 额度头解析 | `codex-rs/codex-api/src/rate_limits.rs` L57–L101（`x-codex-*` 前缀）、L189（`x-codex-rate-limit-reached-type`） | 未下载核对 |
| 额度通知发送 | `codex-rs/app-server/src/bespoke_event_handling.rs` L1590–L1606 | 未下载核对 |
| `exec --json` 只有文本错误 | `codex-rs/exec/src/exec_events.rs` L55–L57（`TurnFailedEvent`）、L92–L94（`ThreadErrorEvent { message }`） | 未下载核对 |

### A.2 公共实验装置（重建所需的最小结构）

隔离 `CODEX_HOME/config.toml`（端口为运行时随机值）：

```toml
model = "m-ok"
model_provider = "fake_a"
approval_policy = "never"
sandbox_mode = "read-only"
check_for_update_on_startup = false

[model_providers.fake_a]           # fake_b 相同，仅路径前缀不同；fake_down 指向已关闭端口
name = "fake_a"
base_url = "http://127.0.0.1:<port>/fake_a/v1"
wire_api = "responses"
env_key = "M1_FAKE_TOKEN"          # 值为合成 token
requires_openai_auth = false
request_max_retries = 1
stream_max_retries = 1
stream_idle_timeout_ms = 5000
```

子进程环境：`CODEX_HOME=<隔离目录>`、`M1_FAKE_TOKEN=<合成值>`；启动前移除所有 `*_API_KEY` 环境变量。fake Provider 是只绑定 `127.0.0.1` 的 HTTP 服务，按请求体 `model` 选择模拟返回：

| 合成模型 | 模拟上游返回 |
|---|---|
| `m-ok` | 200，SSE：`response.created` → `response.output_item.done`（assistant message）→ `response.completed`（含 usage） |
| `m-reason` | 同上，但在 message 前多一个 `response.output_item.done`：`{type:"reasoning", id, summary:[{type:"summary_text", text}], encrypted_content:"<合成字符串>"}` |
| `m-usage` | 429，`{"error":{"type":"usage_limit_reached","message":"…","plan_type":"plus","resets_at":<now+3600>}}`；响应头 `x-codex-primary-used-percent: 100`、`x-codex-primary-window-minutes: 300`、`x-codex-primary-reset-at`、`x-codex-secondary-used-percent: 42`、`x-codex-secondary-window-minutes: 10080`、`x-codex-secondary-reset-at`、`x-codex-rate-limit-reached-type: rate_limit_reached` |
| `m-usage-nohdr` | 与 `m-usage` 相同的 429 体，**无**任何 `x-codex-*` 头 |
| `m-quota` | 429，`{"error":{"type":"insufficient_quota","code":"insufficient_quota","message":"…"}}` |
| `m-notincl` | 429，`{"error":{"type":"usage_not_included","message":"…"}}` |
| `m-rate` | 429，`{"error":{"type":"rate_limit_exceeded","message":"…"}}` |
| `m-503` | 503，`{"error":{"code":"server_is_overloaded","message":"…"}}` |
| `m-500` | 500，`{"error":{"message":"…"}}` |
| `m-401` | 401，`{"error":{"code":"invalid_api_key","message":"…"}}` |
| `m-404` | 404，`{"error":{"code":"model_not_found","message":"…"}}` |

fake Provider 对每个请求只记录：Provider 路径、`model`、`input` 项数、`input` 中出现的 `MARK_*` 标记、`thread-id` 头末 6 位、`x-codex-turn-metadata.request_kind`、`reasoning` 项数、含 `encrypted_content` 的项数、`include`、`store`、授权头是否等于合成 token（布尔值）。

驱动：`codex app-server`（stdio JSON-RPC，逐行 JSON）。每次会话先发 `initialize {clientInfo}`，再发通知 `initialized`；服务端发来的审批请求一律回复 `decline`（本实验未触发）。

### A.3 E1 — 信号分类（两个版本）

步骤：每个合成模型新建一个线程 `thread/start {model, modelProvider, cwd, approvalPolicy:"never", sandbox:"read-only"}` → `turn/start {threadId, input:[{type:"text", text:"MARK_E1_<模型>_<Provider>"}]}` → 等待 `turn/completed`（120 秒未完成则 `turn/interrupt` 清理）。记录该轮所有 `error` 通知（`codexErrorInfo`、`willRetry`）、`account/rateLimits/updated`、最终 `turn.status` / `turn.error.codexErrorInfo`、上游请求次数。

观察（两轮一致；“额度通知”列为 primary% / secondary% / reachedType）：

| 合成模型 | 0.162 `turn.error.codexErrorInfo` | 0.154 | `willRetry` 序列 | 额度通知 | 上游次数 | 判断 |
|---|---|---|---|---|---|---|
| m-ok | —（completed） | 同 | — | 有，全空 | 1 | 成功轮也会发空额度通知，**通知本身不能作为耗尽依据** |
| m-usage | `usageLimitExceeded` | 同 | false | 100 / 42 / `rate_limit_reached` | 1 | 订阅式耗尽可识别（需身份约束） |
| m-usage-nohdr | `usageLimitExceeded` | 同 | false | 有，全空 | 1 | 无额度头时与其他耗尽类不可区分 → UNKNOWN |
| m-quota | `usageLimitExceeded` | **`responseTooManyFailedAttempts{429}`** | false | 无 | 1 | API Key 额度；**版本漂移** |
| m-notincl | `usageLimitExceeded` | 同 | false | 无 | 1 | “套餐不含”，与耗尽共用错误码 |
| m-rate | `responseTooManyFailedAttempts{429}` | 同 | false | 无 | 1 | 普通 429，不是耗尽（G-3） |
| m-503 | `serverOverloaded` | 同 | false | 无 | 2 | 不是耗尽 |
| m-500 | `internalServerError` | 同 | true, false | 无 | 4 | 不是耗尽 |
| m-401 | `httpConnectionFailed{401}` | **`other`** | true, false | 无 | 2 | 不是耗尽；版本漂移 |
| m-404 | `httpConnectionFailed{404}` | **`other`** | true, false | 无 | 2 | 不是耗尽；版本漂移 |
| fake_down | 未完成（120 秒后中断） | 同 | 5 × true（`responseStreamDisconnected{null}`） | 无 | 0 | 网络故障长时间重试，不是耗尽 |

### A.4 E2 / E2b / E2c — 跨 Provider 接续

E2b 步骤（每个变体单独线程）：`thread/start(fake_a, m-ok)` → `turn/start("MARK_<V>_OK")`（成功）→ `turn/start(model:"m-usage", "MARK_<V>_EXHAUSTED")`（`usageLimitExceeded`）→ 变体操作 → `turn/start("MARK_<V>_NEXT")`（不带 model）。两个版本、两轮结果一致：

| 变体 | 操作 | 返回的线程设置 | 下一轮实际上游 | 下一轮历史中可见的先前标记 | 判断 |
|---|---|---|---|---|---|
| V1 | 同进程 `thread/unsubscribe` → `thread/resume {threadId, model:"m-ok"}` | fake_a / m-usage | fake_a / m-usage（失败） | OK、EXHAUSTED | 忽略 |
| V2 | 同进程 unsubscribe → `thread/resume {threadId, modelProvider:"fake_b", model:"m-ok"}` | fake_a / m-usage | fake_a / m-usage（失败） | OK、EXHAUSTED | 忽略 |
| V3 | 关闭进程，**新 app-server 进程** `thread/resume {threadId, modelProvider:"fake_b", model:"m-ok"}` | fake_b / m-ok | fake_b / m-ok（成功；再下一轮仍为 fake_b） | OK、EXHAUSTED | 生效，同线程 id，粘性 |
| V4 | `thread/fork {threadId, modelProvider:"fake_b", model:"m-ok"}` | fake_b / m-ok，新线程 id | fake_b / m-ok（成功） | OK、EXHAUSTED | 生效，新线程 id |

E2c：V2 形式，unsubscribe 后分别等待 0 / 3 / 12 秒再 resume。三种等待下均返回 fake_a / m-usage，且均未观察到该线程的 `thread/*` 状态通知 → 忽略。

**与历史结果矛盾**：`HOT_SWITCH_FEASIBILITY_GATE.md` §15.4 A5 记录同进程 unsubscribe → resume（同 Provider、仅换模型）**生效**；本研究 V1（同形态）在 0.154 与 0.162 上均**被忽略**。差异原因未查明（历史线程没有经历失败轮及 `turn/start(model)` 覆盖，可能是差异因素，但未验证）。本研究不推翻历史记录，只报告当前观察（U6）。

E2（首轮）：fork 步骤误指向 fake_a，结果不计入结论；其余步骤与 E2b 一致。

### A.5 E3 / E3b — 托管 app-server 与双客户端（TUI 为模拟）

步骤：`codex app-server --listen ws://127.0.0.1:<port> --ws-auth capability-token --ws-token-sha256 <sha256(合成 token)>`；WebSocket 握手头 `Authorization: Bearer <token>`；客户端 A（模拟 TUI）与 B（模拟 Manager）各自 `initialize`。两个版本、两轮结果一致：

| 步骤 | 观察 | 判断 |
|---|---|---|
| 无 token 握手 / 错误 token 握手 | `HTTP/1.1 401 Unauthorized` / 同 | 认证生效 |
| 正确 token | `101 Switching Protocols` ×2 | — |
| A：`thread/start(fake_a, m-ok)` + 成功一轮；B：`thread/resume {threadId}` | B 得到 fake_a / m-ok | B 订阅成功 |
| A：`turn/start(model:"m-usage")` | B 收到 `turn/completed(failed)`、`error=usageLimitExceeded`、`account/rateLimits/updated`（100、`rate_limit_reached`） | 托管形态下 Manager 可观察信号 |
| B：`thread/resume {threadId, modelProvider:"fake_b", model:"m-ok"}`（线程由 A 加载中） | 返回 fake_a / m-usage | 忽略 |
| B：`thread/fork {…fake_b, m-ok}` | 新线程 id，fake_b / m-ok | 生效 |
| A：原线程普通一轮 | 上游 fake_a / m-usage | A 不跟随 fork |
| E3b：B：`turn/start {threadId, model:"m-ok", input:"MARK_E3B_MANAGER_TURN"}` | 上游 fake_a / m-ok；A 收到该轮 `turn/completed` | 同 Provider 原线程切换可行（需输入） |
| E3b：A：原线程普通一轮 | 上游 fake_a / m-ok | 粘性 |

首次 E3b 运行中“A 下一轮无上游请求”是驱动脚本误消费事件所致，已修正后重跑；修正后的两轮结果一致。

### A.6 E4 — 跨 Provider 后的 reasoning 回放

步骤：`thread/start(fake_a, m-reason)` → 轮 T1 → 同 Provider 轮 T2 → `thread/fork(fake_b, m-ok)` 后首轮；另一线程在 fake_a 上完成一轮后关闭进程，**新进程** `thread/resume(fake_b, m-ok)` 后首轮。两个版本、两轮结果一致：

| 请求 | reasoning 项数 | 含 `encrypted_content` 的项数 | `include` | `store` |
|---|---|---|---|---|
| T1（fake_a） | 0 | 0 | `["reasoning.encrypted_content"]` | false |
| T2（fake_a，同 Provider） | 1 | 1 | 同 | false |
| fork 后首轮（fake_b） | 2 | 2 | 同 | false |
| 新进程 resume 后首轮（fake_b） | 1 | 1 | 同 | false |

判断：两个版本在切换 Provider 后都**不剥离**先前 Provider 产生的加密 reasoning 项。真实 ChatGPT 后端的 reasoning 项是否同形（C/D）未验证。

### A.7 E5 / E5b — 请求形状捕获与 Router 解析器判定

E5 步骤（0.162）：`thread/start(fake_a, m-reason)` → 一轮（样本 S1 = 该轮请求体）→ `thread/fork(fake_b, m-ok)` → 一轮（样本 S2）。样本只在本机用于解析器调用，**不提交**。最小结构（只列键与类型，不含正文）：

- 根字段（S1、S2 相同）：`client_metadata`（对象，键：`root_turn_id`、`session_id`、`thread_id`、`turn_id`、`x-codex-installation-id`、`x-codex-turn-metadata`、`x-codex-window-id`）、`include`（`["reasoning.encrypted_content"]`）、`input`、`model`、`parallel_tool_calls`（true）、`prompt_cache_key`、`reasoning`、`store`（false）、`stream`、`tool_choice`、`tools`。
- `tools`（9 项，按序）：`function exec_command`、`function write_stdin`、`function request_user_input`、`function view_image`、`namespace multi_agent_v1`（5 个子工具）、`function get_goal`、`function create_goal`、`function update_goal`、`web_search`。
- S2 `input` 中回放的 reasoning 项键：`type`、`id`、`summary`、`content`、`encrypted_content`。

E5b 步骤：在本 worktree 执行 `dotnet build local-router/src/Router.ClientAdapters.Responses -c Release`，在仓库外的一次性控制台程序中引用其产物，调用 `ResponsesRequestParser.TryParse(json, out _)`，对每个样本运行 §5.5 表中的各变体（只在内存中改动样本副本；仓库代码与文件不变）。结果见 §5.5；首轮与复跑一致，逐字段加回与边界对照为复跑新增。

### A.8 开发者报告、待独立复现的结论清单

以下结论来自 B 级实验，脚本未入库，**仅为开发者报告，待独立复现**：

1. E1 的分类表（含 0.154 / 0.162 版本漂移）；
2. E2b–E2c 的 resume / fork 行为，以及与历史 §15.4 的矛盾；
3. E3/E3b 的 WebSocket 认证、双客户端观察与同 Provider 切换；
4. E4 的 reasoning 回放行为；
5. E5b 的解析器逐变体判定（解析器代码本身可独立核对，但判定依赖未入库的样本）。

独立复现所需：同版本二进制、A.2 的配置与模拟返回、A.3–A.7 的步骤。若复现结果不同，应以复现结果为准并更新本文件。
