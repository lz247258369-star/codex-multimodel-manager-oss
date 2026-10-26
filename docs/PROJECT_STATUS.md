# 项目实际进度（PROJECT_STATUS）

> 状态：**草案（DRAFT）——待项目经理独立验收、老板批准。**
> 本文件只记录可在 Git / GitHub 中核实的事实。没有 Git 依据的需求一律列为“待老板确认”，不作为既定事实。
> 老板已明确提出的核心产品需求（G-1…G-5）属于“已确认的产品目标”，记录在 [PRODUCT_VISION.md](PRODUCT_VISION.md) §2；本文件只记录它们的实现与验收状态。合并本规划文档不等于批准 V1 范围。

| 项 | 值 |
|---|---|
| 审计日期 | 2026-10-12 |
| 审计基线 `main` | `2abc868896f167006ad65eb4ec8c3b7b2eb25477`（Merge PR #103） |
| `main` CI | Development Gate run #319 — **success**（私有开发仓库中的运行记录，未随开源快照公开） |
| PR 统计（截至审计，编号 #1–#104） | **已合并 99 个**：#1–#52、#54–#66、#68–#87、#89–#92、#94–#103；**关闭未合并 1 个**：#53；**仍为 Draft / 未合并 4 个**：#67、#88、#93、#104（本规划 PR）。来源：`gh pr list --state all`。“已合并”只表示代码进入 `main`，不表示实际用户环境验收。 |
| 仓库内版本标识 | `manifest.json` = `3.8.0`（2026-08-23），`CHANGELOG.md` 最新条目 = 3.8.0，`README.md` 只描述到 V3.5 |

## 0. 状态图例

| 标记 | 含义 |
|---|---|
| ✅ 已合并·CI 验证 | **已进入 main 的代码能力**：已合并到 `main`，且 `main` 上 Development Gate 通过。**CI 证据为 GitHub 托管 Windows runner 上的离线/fake/隔离环境证据，不等于真实 Provider、真实 Codex Desktop 或正式 Windows 安装环境的验收。** |
| 🧪 实际用户环境验收 | **已通过实际用户环境验收的能力**：在真实 Windows、真实 Codex、真实 Provider 环境中有可追溯验收记录。**截至本审计，Git 中没有任何能力的正式实际用户环境验收记录。** |
| 🔬 技术可行性待研究 | 已确认的产品目标，但当前尚无经过验证的可行实现，需要独立技术可行性研究。 |
| 🟡 已实现·未合并 | 代码存在于 Draft PR 或分支，未进入 `main`，不得视为完成。 |
| 📐 仅设计 | 有设计文档或研究结论，无生产实现。 |
| ⬜ 未实现 | 既无实现也无被批准的设计。 |
| 🚫 外部平台限制 | 已有研究证据表明受 Codex CLI / Desktop 平台限制、当前无官方可行路径的具体机制（只用于有证据的事实，不用于产品目标）。 |
| ❓ 待老板确认 | 需求或范围在 Git 中缺乏依据，或存在多种解释。 |

## 1. 模块完成情况

### 1.1 Direct Mode 管理器（V2–V3.8，PowerShell + Skill）

| 能力 | 状态 | 依据 |
|---|---|---|
| 一键 Provider 配置、API Key 仅存用户环境变量 | ✅ | PR #1–#16，CHANGELOG 2.0.0–3.3.5 |
| ChatGPT 订阅账户官方模型优先启动（G-1），账户支持的官方模型回落 | ✅ | CHANGELOG 3.3.7（ChatGPT profile 不再硬编码模型） |
| 安全切换（新会话启动），Git handoff 快照与校验 | ✅ | CHANGELOG 2.0.0、3.3.4；PR #8 |
| Codex Profile V2 迁移、旧自定义 catalog 隔离 | ✅ | PR #10、#12 |
| 模型自动发现、候选注册、显式批准后注册、每周检查 | ✅ | CHANGELOG 3.0.0；`skill/.../discover-models.ps1` 等 |
| 付费 Responses / tool-calling 探测（需显式确认） | ✅（机制） | CHANGELOG 3.0.0；AGENTS.md 第 9 条 |
| Stealth Model Registry（Ox Alpha 等匿名模型生命周期） | ✅ | PR #3、#4；`docs/STEALTH_MODEL_REGISTRY.md` |
| 一键 Health Check 与显式安全修复 | ✅ | PR #13、#14；`docs/HEALTH_CHECK.md` |
| Development Gate CI | ✅ | PR #2；`.github/workflows/ci.yml` |

### 1.2 可视化界面

| 能力 | 状态 | 依据 |
|---|---|---|
| V3.5–3.8 WPF Desktop Controller（Provider/品牌/版本/推理强度选择、健康驾驶舱） | ✅ | PR #17–#25 |
| V4 Visual Console（深色卡片式界面、模型矩阵、单实例、任务栏品牌、崩溃日志） | ✅ | PR #26–#66；`docs/VISUAL_CONSOLE.md` |
| V4 → Codex Desktop 第三方 Direct 路由（Desktop Chat route 跟随所选模型） | ✅ | PR #31、#52、#64、#65 |
| V4 Local Router 页面（LR-14：状态、CLI/Desktop 路由、用量/成本、策略、Safe Restore） | ✅ | PR #84、#87；`docs/LOCAL_ROUTER_V4_UI.md` |
| V4 界面中的“额度耗尽自动切换”控制与状态展示 | ⬜ | 无代码；依赖 HS-1C（未合并） |

### 1.3 Local Router（C# / .NET 10，`local-router/`）

正式路线图见 `docs/LOCAL_ROUTER_RUNTIME_ROADMAP.md`（LR-0 … LR-15）。默认配置 `local-router/config/router.defaults.json`：`mode = direct`、`local_router.enabled = false`、`thread_selection.enabled = false`。

| 切片 | 状态 | PR |
|---|---|---|
| LR-0 架构门 | ✅ | #68 |
| LR-1 核心骨架 / LR-2 配置·状态·密钥 / LR-3 Responses 入口 | ✅ | #69、#70、#71 |
| LR-4 注册表·路由解析 / LR-5 Provider Harness | ✅ | #72、#73 |
| LR-6 OpenRouter / LR-7 Model Studio / LR-7A OpenAI API / LR-7B MiMo 适配器 | ✅（仅 fake upstream 验证） | #74–#77 |
| DeepSeek 直连适配器 + Router bootstrap | ✅（仅 fake upstream 验证） | #90 |
| LR-8 协议边界 / LR-9 健康·追踪 / LR-10 用量·成本 / LR-11 策略·重试·熔断 | ✅ | #78–#81、#85、#86 |
| LR-12 Codex CLI 集成（opt-in） | ✅ | #82；`docs/CODEX_CLI_COMPATIBILITY_MATRIX.md` |
| LR-13 Codex Desktop 集成（opt-in） | ✅（代码）/ **Desktop 实机矩阵多数为 NOT VERIFIED** | #83；`docs/CODEX_DESKTOP_ROUTER_COMPATIBILITY_MATRIX.md` |
| LR-14 V4 UI 集成 + LR-14P 控制面契约 | ✅ | #84、#87 |
| LR-15 加固与发布 | **进行中** | 见 1.4 |

**明确未做：** 任何真实 Provider 的在线/付费评测；跨模型自动回退（LR-11 中 HARD OFF）；Chat Completions 协议；远程监听。

### 1.4 LR-15 加固、打包与发布

| 子项 | 状态 | PR / 依据 |
|---|---|---|
| PR1 HS-1B 线程级模型选择（slice 1） | ✅（默认关闭） | #89 |
| PR2 Router bootstrap + DeepSeek | ✅ | #90 |
| PR3 能力诊断与不支持工具的拒绝 | ✅ | #91 |
| PR4 apply_patch 兼容桥 | ✅ | #92 |
| PR5 Desktop namespace / tool_search 识别（仅识别，仍 fail-closed） | ✅ | #97（#93 为同主题旧 Draft，疑似已被取代 ❓） |
| CI / Host 可靠性修复 | ✅ | #94、#95、#96 |
| PR6 可验证发布包与来源证明 | ✅ | #98 |
| PR7 安装所有权清单与卸载计划 | ✅ | #99 |
| PR8 安全卸载执行器 | ✅（代码）/ **生产上不可执行**：缺少 stopped lease | #100 |
| PR9 Router Host win-x64 发布包 | ✅（独立组件，**禁止直接安装**） | #101 |
| PR10A Windows Host 启动协调门 | ✅ | #102 |
| PR10B Host 生命周期控制器（Status / Start / Stop） | ✅ | #103 |
| PR6 包与 PR9 Host 的组合账本（composition stage） | ⬜ | `ROUTER_HOST_RELEASE.md`、路线图 PR9 小节 |
| `InstallationId ↔ InstallRoot ↔ Host ↔ RuntimeDirectory ↔ 进程` 绑定与 PR8 stopped lease | ⬜（明确 BLOCKED） | `docs/ROUTER_HOST_LIFECYCLE.md` §BLOCKED 1 |
| 升级 / 回滚演练 | ⬜ | 路线图 LR-15 Definition of Done |
| 代码签名、第三方证明、跨机器可复现构建 | ⬜ | 路线图 PR6 小节 |
| 受支持 Windows 版本上的发布矩阵、干净机器安装测试 | ⬜ | 路线图 General release gate |
| 用户安装入口（Router 的一键安装/升级/卸载 UX） | ⬜ | 无代码 |

### 1.5 额度管理与自动切换（产品核心诉求）

| 能力 | 状态 | 依据 |
|---|---|---|
| 同一 Codex 线程内切换模型（Router 侧线程级覆盖，HS-1B） | ✅（slice 1，默认关闭） | #89；`docs/HS1B_ROUTER_THREAD_MODEL_OVERRIDE_DESIGN.md` |
| 额度/余额耗尽时，在 **Router 管理的第三方 Provider 之间** 粘性切换到备用模型；未耗尽保持；手动选择优先、手动后下次耗尽仍自动切换；不自动切回（HS-1C，对应 G-2…G-5 的第三方额度部分） | 🟡 | Draft #88（基于旧 HS-1B 分支，落后 `main` 93 个提交，CI 未在当前 `main` 上运行）；`ci/hs1c-validation` 分支无 PR。#88 描述包含“多候选耗尽接力”，但“全部备用模型不可用时有界停止并输出明确失败状态”（G-6）是否完全满足，尚未在当前 `main` 上复核 |
| 额度切换的基础历史记录与 V4 展示 | ⬜ | 无代码；HS-1B 设计明确不持久化线程选择，历史记录需要单独设计 |
| **ChatGPT 订阅额度耗尽 → 自动切换到可用备用模型**（G-1…G-5 的核心场景） | 🔬 | **已明确的产品目标；当前尚无经过验证的可行实现；需要独立技术可行性研究。** 已知事实：ChatGPT 账户 Provider 在 Router 架构中为 `DIRECT_ONLY`（`LOCAL_ROUTER_RUNTIME_ARCHITECTURE.md` 第 186 行），Router 不读取 `auth.json`、不代理 ChatGPT 账户凭据，因此现有 Router 看不到 ChatGPT 订阅额度耗尽事件；Git 中尚无覆盖这一场景的设计或实现。这不表示无法实现，也不表示已经可以实现。OpenAI API 额度（`mm_openai_api`）是独立来源，不能代替。 |
| 主动额度查询 / 实时余额 | ⬜（设计上明确不做主动探测） | CHANGELOG 3.8.0；#88 描述“no active quota probes” |

### 1.6 Codex 平台能力边界（研究结论）

| 事实 | 状态 | 依据 |
|---|---|---|
| Codex Desktop 原生模型选择器不显示自定义 / Router 模型 | 🚫 | `HOT_SWITCH_FEASIBILITY_GATE.md` §8 |
| Windows 上没有可附着的 Desktop app-server 控制通道 | 🚫 | 同上 §15.7 |
| 已加载线程的 `thread/resume(model=…)` 会被忽略 | 🚫 | 同上 §15.3 |
| CLI 会话内 `/model`（内置 catalog 内）可用 | ✅（研究证据） | 同上 §7 |
| 通过 OpenCodex 把第三方模型注入原生选择器 | 🟡 | Draft #67（第三方依赖，落后 `main` 130 个提交） |

## 2. 未合并工作清单

| 对象 | 内容 | 与 `main` 关系 | 判断 |
|---|---|---|---|
| Draft PR #88 `feat/hs1c-quota-exhaustion-sticky-failover` | HS-1C 额度耗尽粘性切换 | base = `feat/hs1b-thread-scoped-model-selection`；落后 93 / 领先 20 | 核心诉求的唯一实现，需要在当前 `main` 上重新建立基线 |
| 分支 `ci/hs1c-validation`（无 PR） | HS-1C 的 CI 验证分支 | 21 个独有提交 | ❓ 与 #88 合并处理 |
| Draft PR #67 `feat/native-codex-model-picker` | OpenCodex 原生选择器模式 | 落后 130 / 领先 23；CI 曾成功 | ❓ 是否采用第三方依赖 |
| Draft PR #93 `review/lr15-pr5-tool-taxonomy-recognition` | PR5 旧版 | CI 失败；同主题 #97 已合并 | ❓ 疑似已被 #97 取代，建议关闭 |
| 分支 `feat/dsr7c-apply-patch-compat-bridge`（无 PR） | **远端可核实**：远端分支相对 `main` 落后 93 / 领先 31；按补丁内容比较，远端分支有 1 个 `main` 中没有的 CI 相关提交 `6df2cbb`。**开发者报告，本轮远端 GitHub 无法独立核实**：开发机本地该分支另有 1 个未推送提交 `0bfe40a`；PR #89 描述称其内容已 cherry-pick 为 `6c5e6b6`（`6c5e6b6` 在 `main` 中可核实）。 | 见左 | ❓ 疑似已被 #89/#92 取代；**未清理，等待老板决定** |
| 分支 `research/hot-switch-feasibility-gate`（无 PR） | 热切换研究文档 | 文档内容已存在于 `main` | 历史分支 |

本审计未修改、清理或重置任何 worktree 或分支。

## 3. 文档与版本一致性缺口

- `README.md` 只描述到 V3.5，未提及 V4 Visual Console、Local Router、LR-15 发布工具。
- `CHANGELOG.md` 停在 3.8.0（2026-08-23），之后的 V4 与 Local Router 工作无条目。
- `manifest.json` 版本仍为 `3.8.0`。
- 产品层面没有统一的“V1”定义；“V1”在仓库中多处指 schema v1 / contracts v1，并非产品版本（见 `PRODUCT_VISION.md` §3）。
- 本审计新增 `PRODUCT_VISION.md`、`MASTER_ROADMAP.md`、本文件与根目录 `CLAUDE.md` 作为总控文档草案。

## 4. 已知环境与验证限制

- 真实 Provider 在线评测从未执行（付费推理需要老板逐次确认）。所有 Provider 适配器证据均来自 fake upstream。
- Codex Desktop 兼容矩阵（LR-13）在验证时 Desktop 未安装，多数条目为 NOT VERIFIED；之后的热切换研究使用了 Desktop MSIX `26.903.9818.0`，但只覆盖协议层，未覆盖 Desktop UI 闭环。
- **CI 成功 ≠ 正式 Windows 安装环境验收。** CI 运行在 GitHub 托管的英文、提升权限 Windows runner 上，不覆盖中文系统、非管理员用户、受沙箱影响的目录 ACL 等真实用户环境。

### 4.1 开发环境限制（开发者报告，本机观察，不影响 GitHub CI）

| 现象 | 影响 |
|---|---|
| 非提升权限会话无法创建符号链接 | 本地 `validate-repo.ps1` 中 safe-uninstall、Host release、startup-gate 三个验证器失败 |
| 中文 Windows 的错误消息是中文，startup-gate 脚本的“权限不足则跳过”分支只匹配英文消息 | 本地 startup-gate 验证中断，后续原生用例未执行 |
| `%TEMP%` 被 Codex Windows 沙箱授予 `CodexSandboxUsers` Modify 权限 | PR10A 启动门在本地**正确地**拒绝 `%TEMP%` 下的运行目录，control-plane bootstrap 等验证失败 |

这些是开发环境限制：以 GitHub Windows CI 为准，且**不得为此放松任何安全检查**（见 `CLAUDE.md` §4）。

### 4.2 潜在用户兼容性风险（待验证，非已证实缺陷）

| 风险 | 说明 | 需要的证据 |
|---|---|---|
| 中文（及其他非英文）Windows | 若产品运行时代码也像上述测试脚本一样按英文消息文本判断错误，在非英文系统上可能走错分支 | 在中文 Windows 上做安装与运行验收；审查运行时代码中按消息文本判断的位置 |
| 非管理员用户 | 若安装/运行路径依赖符号链接或提升权限，普通用户可能失败 | 非管理员账户的干净机器安装验收 |
| 目录 ACL 被其他软件放宽（例如沙箱工具组） | Router 运行目录若位于被放宽的目录下，启动门会按设计拒绝启动；用户看到的是“Router 无法启动” | 确认产品默认运行目录的 ACL 行为与用户可理解的错误提示；**不得以放松启动检查作为解决方案** |

## 5. 更新规则

- 每个 PR 合并后，由开发工程师在下一个任务开始前核对并更新本文件（只写有 Git/CI 依据的事实）。
- 本文件的“状态”栏不得从 🟡/📐/⬜ 提升为 ✅，除非对应提交已在 `main` 且 `main` CI 成功。
- “真实环境验收”（实机 Desktop、真实 Provider、干净机器安装）与 CI 通过分开记录；只有存在可追溯验收记录时才可标为 🧪。
- 🔬 条目在独立可行性研究给出证据之前，不得改写为“可实现”或“不可能实现”。
