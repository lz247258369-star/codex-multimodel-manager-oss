# 总路线图（MASTER_ROADMAP）

> 状态：**草案（DRAFT）——待项目经理独立验收、老板批准。**
> 本文件把[产品蓝图](PRODUCT_VISION.md)拆成版本里程碑。**§2 的 V1 范围是“建议”，经老板逐项批准后才成为正式范围。合并本规划文档不等于批准 V1 全部功能。** 已有的 Local Router 工程路线图 `LOCAL_ROUTER_RUNTIME_ROADMAP.md`（LR-0…LR-15）是本文件的子路线图，继续有效。
> 状态分类与 PRODUCT_VISION §0 一致：已确认的产品目标 / 待批准的 V1 范围 / 技术可行性待研究 / 已进入 main 的代码能力 / 已通过实际用户环境验收的能力。
> **本文件是“长期路线与 V1 范围”的权威来源。** 当前真实进度与下一项排定任务只在 [PROJECT_STATUS.md](PROJECT_STATUS.md) 中维护，本文件的“现状”列只做摘要；两者不一致时以 PROJECT_STATUS（及真实 Git）为准。

**名称约定：** 本文件的 M0…M6 是**产品里程碑**。项目经理下发的 `OSS-M1`…`OSS-M4-x` 是开源仓库迁移与工程基线的**任务编号**，与产品里程碑无关；例如 `OSS-M4-2` 不是本文件的 M4（V1 发布候选）。

## 1. 里程碑总览

```text
M0  已交付基础（V2–V3.8 Direct Mode、V4 界面、Router LR-0…LR-14、LR-15 PR1–PR10B）
 │
M1  V1 决策准备：ChatGPT 订阅额度检测与自动切换的独立技术可行性研究
 │   （提供证据与推荐方案；仅研究，不写生产代码）
 │
M2  V1 范围冻结：老板基于 M1 证据批准本文件 §2、§3 与 PRODUCT_VISION §6 的决策
 │   （只能由老板冻结；开发工程师与项目经理不得擅自冻结）
 │
M3  V1 功能补齐（按 §4.2 顺序：HS-1B 必要依赖 → HS-1C → ChatGPT 订阅额度切换（若获批）
 │   → V4 状态与基础历史 → 发布组合 → 安装升级回滚 → 文档）
 │
M4  V1 发布候选（RC）：CI + 实际用户环境验收 + 干净机器安装 + 回滚演练
 │
M5  V1 正式发布
 │
M6+ V1 之后的版本（§5）
```

每个里程碑内部仍遵守“一次一个已批准任务、一个独立可审查 PR”的开发规则（见根目录 `CLAUDE.md`）。M1 的研究结论无论如何，V1-11 都保留在 V1 决策清单中，由老板在 M2 决定。

当前位置（2026-11-26 核对）：M0 已交付，并且 HS-1C（Router 内第三方额度耗尽粘性切换）已随 genesis 导入进入 `main`。M1 研究已完成（结论 PARTIALLY_FEASIBLE，见 [CHATGPT_SUBSCRIPTION_QUOTA_FAILOVER_FEASIBILITY.md](CHATGPT_SUBSCRIPTION_QUOTA_FAILOVER_FEASIBILITY.md)）。**M2 范围冻结尚未在 Git 中记录**：§2 全部条目仍是“建议”。M3 中当前锁定的施工顺序见 §4.3。

## 2. V1 建议范围（待老板批准）

本表**全部条目均为“待批准的 V1 范围”**，老板批准前不构成正式 V1 范围。
标记：**必备** = 建议 V1 必须包含；**可选** = 老板可决定移出 V1；❓ = 依赖 PRODUCT_VISION §6 的决策。
“目标”列标注该条目是否属于**已确认的产品目标**（PRODUCT_VISION §2 的 G-1…G-5）或其安全边界要求 G-6。
“现状”只引用 [PROJECT_STATUS.md](PROJECT_STATUS.md) 中有 Git 依据的事实；✅ 表示**已进入 main 的代码能力**，不表示已通过实际用户环境验收（目前 Git 中没有任何一项的正式实际用户环境验收记录）。

| # | 功能 | 目标 | 建议 | 现状 | 缺口 |
|---|---|---|---|---|---|
| V1-01 | ChatGPT 订阅账户官方模型优先启动（Direct） | G-1 | 必备 | ✅ | 实际用户环境验收 |
| V1-02 | 一键 Provider 配置与密钥引用（Direct） | — | 必备 | ✅ | 实际用户环境验收 |
| V1-03 | 安全切换 + Git handoff | — | 必备 | ✅ | — |
| V1-04 | 模型发现 → 显式探测 → 显式批准 | — | 必备 | ✅ | 实际用户环境验收 |
| V1-05 | Health Check 与安全修复 | — | 必备 | ✅ | — |
| V1-06 | V4 Visual Console（模型矩阵、Provider、健康） | — | 必备 | ✅ | 实际用户环境验收 |
| V1-07 | Codex CLI Router 集成（opt-in，可精确恢复） | — | ❓ 必备/可选 | ✅ 代码 | 真实 Provider 端到端证据（付费，需批准） |
| V1-08 | Codex Desktop Router 集成（opt-in） | — | ❓ 可选 | ✅ 代码 | Desktop 实机兼容矩阵大量 NOT VERIFIED |
| V1-09 | 线程级模型选择（HS-1B） | — | ❓ 可选 | ✅ slice 1，默认关闭 | 后续 slice 范围未定义；Desktop 实机验证 |
| V1-10 | **Router 内第三方 Provider 之间额度耗尽粘性切换（HS-1C）**，含“全部备用模型不可用时的明确失败状态” | G-2、G-3、G-6 | ❓ 建议必备 | ✅ 代码（私有 #108、#110，随 genesis 导入；默认关闭；仅 fake Provider 验证） | 错误码的 HTTP 状态映射（私有 Draft #111，未迁移）；实际用户环境验收 |
| V1-11 | **ChatGPT 订阅额度耗尽 → 自动切换到可用备用模型** | G-1…G-6 | ❓ **V1 范围待老板在 M2 决定（保留在 V1 决策清单，不默认移至后续版本）** | **已明确的产品目标；当前尚无经过验证的可行实现。** M1 研究已完成：PARTIALLY_FEASIBLE（CLI 部分可行，Desktop 当前 BLOCKED，最高证据 A/B） | 老板在 M2 基于研究证据决定；“提示 + 一键切换”只能经老板批准后作为降级方案 |
| V1-12 | 手动切换优先 + 后续耗尽仍自动切换 + 不强制切回原模型 | G-4、G-5 | ❓ 随 V1-10 / V1-11 | Router 内：✅ 代码，随 V1-10；ChatGPT 订阅额度：同 V1-11 | 同 V1-10 / V1-11 |
| V1-13 | V4 中额度切换的当前状态、切换原因与**基础历史记录**（按时间列出每次切换：时间、来源模型、目标模型、原因、结果；含全部不可用的失败记录） | G-2、G-6 | ❓ 随 V1-10 / V1-11 | 🟡 私有 Draft #113（Router 侧）、#114（V4），未迁移 | 是否迁移由项目经理 / 老板决定；高级查询/筛选/统计/通知属于 V1.1，不在 V1 重复建设 |
| V1-14 | Router Host 生命周期（Status/Start/Stop） | — | 必备（若 Router 进 V1） | ✅ PR10B | 与安装组合的绑定 |
| V1-15 | 发布包组合（PR6 包 + PR9 Host 统一账本） | — | 必备（若 Router 进 V1） | 🟡 私有 Draft #115 已实现，**未迁移** | §4.3 第 1 项：迁移、复审、CI |
| V1-16 | 安装 / 安全卸载（含 stopped lease） | — | 必备 | ✅ 组件已在 `main`，但整体流程不可用；BIND1 安装身份绑定在私有仓库已实现，**未迁移** | §4.3 第 2 项 BIND1；随后提供 PR8 stopped lease |
| V1-17 | 升级与回滚演练 | — | 必备 | ⬜ | 设计 + 演练脚本 + 证据 |
| V1-18 | 用户文档（README 中英文）、CHANGELOG、已知限制 | — | 必备 | ⬜（文档停在 V3.5/3.8.0） | 文档切片 |
| V1-19 | 代码签名 / 发布渠道 | — | ❓ | ⬜ | 老板决定是否需要 |
| V1-20 | OpenCodex 原生选择器模式（#67） | — | ❓ 建议不进 V1 | 🟡 Draft | 第三方依赖决策 |

**不得**因为某项尚未实现、或技术可行性尚未研究，就把它从 V1 删除或移至后续版本；删除或延期必须由老板在本表中明确批准。OpenAI API 额度（`mm_openai_api`）是独立的额度来源，不能用来满足 V1-11。

## 3. V1 正式发布验收标准（建议）

V1 只有在以下全部满足时才能发布。每一条都必须有可追溯证据（PR、CI run、验收记录），不得以“本地通过”代替 CI，也不得以 CI 通过代替实机验收。

### 3.1 工程门

1. `main` 上 Development Gate CI 成功，且 V1 涉及的全部 PR 均已合并、无失败 check。
2. 没有未关闭的严重/高危安全问题；密钥扫描、运行态文件扫描通过。
3. 默认配置保持 `mode = direct`、`local_router.enabled = false`、跨模型通用回退 OFF；额度切换功能默认状态由老板决定并写入本文件。
4. Direct Mode 回归（CLI、Desktop、ChatGPT 账户）通过。

### 3.2 功能验收（实机）

5. 在一台受支持的 Windows 实机上，按用户手册完成：安装 → 配置 Provider → ChatGPT 订阅账户官方模型启动 → 第三方模型启动 → Health Check。
6. 对 V1 批准范围内的每一种额度来源（Router 内第三方 Provider；若 V1-11 获批，则包括 ChatGPT 订阅额度）：用受控方式（fake 或老板批准的真实额度场景）证明“只有明确耗尽才切换、未耗尽保持、手动优先、手动后下次耗尽仍自动切换、不自动强制切回”，并在 V4 中看到切换原因。ChatGPT 订阅额度与 OpenAI API 额度分别验收，不得互相代替。同时证明 G-6：当全部已批准的备用模型都不可用时，系统在有界次数内停止尝试、输出明确的失败状态与原因，不无限重试，也不在未经用户确认的情况下选择未批准的其他 Provider 或模型；该失败记录出现在 V4 的基础历史记录中。
7. 若 V1 包含 Desktop Router：Desktop 兼容矩阵中 V1 依赖的条目全部从 NOT VERIFIED 变为有证据的 SUPPORTED/UNSUPPORTED。
8. 真实 Provider 端到端调用（每个 V1 Provider 至少一次）——**属于付费推理，每次需老板确认**；未获批准的 Provider 不得标为“已验证”。

### 3.3 安装与恢复

9. 干净机器安装成功；安装只写入自己拥有的文件。
10. 安全卸载只删除所有权清单内且校验通过的文件；未知文件保留。
11. 升级（N-1 → N）与回滚（N → N-1）演练成功，Codex 配置可精确恢复。
12. Router 损坏、端口冲突、进程崩溃时报告 UNKNOWN/FAILED 而非误报，并能 Safe Restore 回 Direct。

### 3.4 发布物

13. 发布包通过 `-Verify` 来源校验；发布说明包含版本、源提交、已知限制、支持矩阵。
14. README（中/英）、CHANGELOG、`manifest.json` 版本与发布一致。

## 4. 建议实施顺序

每项一个独立 PR（研究项为文档 PR），**逐项由老板批准开工**。下列顺序是建议，不构成范围冻结。

### 4.1 范围冻结前（M1 → M2）

1. **ChatGPT 订阅额度检测与自动切换的独立技术可行性研究**（M1；仅研究，无生产代码，无付费推理除非老板另行批准）：输出证据、可行/不可行/未知的结论、推荐方案与备选方案。研究结论出来前，V1-11 保持“已明确的产品目标；当前尚无经过验证的可行实现”，并始终留在 V1 决策清单。
2. **老板决策与 V1 范围冻结**（M2）：老板基于研究证据批准 §2、§3 与 PRODUCT_VISION §6 的决策，并按 §7 记录批准。开发工程师与项目经理不得擅自冻结。

### 4.2 范围冻结后（M3，仅针对老板批准的条目）

3. **HS-1B 必要依赖核对与补齐**：核对 HS-1C（#88，原 base 为 HS-1B 累积分支）依赖的 HS-1B 能力是否已全部随 #89 进入 `main`；缺失的部分作为单独的前置切片，不并入 HS-1C。
4. **HS-1C 重建基线**（V1-10、V1-12）：把 #88 / `ci/hs1c-validation` 在当前 `main` 上重新建立为可审查 Draft PR（不改变其已审语义），补齐 CI，并按 G-6 验证全部备用模型不可用时的失败语义。
5. **ChatGPT 订阅额度切换实现**（V1-11，仅当老板在 M2 批准且研究给出可行方案；依赖 4 的切换语义）。
6. **V4 额度切换状态与基础历史记录**（V1-13；依赖 4，若 5 获批也依赖 5）。
7. **LR-15 组合阶段**：PR6 包与 PR9 Host 的统一账本、安装绑定，从而让 PR8 stopped lease 可被安全提供。
8. **升级 / 回滚演练**与证据。
9. **Desktop 实机兼容矩阵补证**（需要 Desktop 安装环境，不做付费推理）。
10. **用户文档与发布说明**（README、CHANGELOG、manifest）。
11. **发布候选验收**（M4，§3，含经批准的付费实测）。

7–10 与 3–6 没有代码依赖，老板可以批准调整其先后，但每次仍只执行一个已批准任务。

核对（2026-11-26）：第 3、4 项已在私有仓库完成（私有 #108 在当时的 `main` 上重建 HS-1C，#110 补齐安装器配置），随 genesis 导入进入本仓库；`main` 中的 HS-1C 包含 G-6 的有界失败 `quota_fallbacks_exhausted`。

### 4.3 当前锁定的施工顺序（OSS-M4-3 起）

来源：项目经理 OSS-M4-3 任务书（2026-11-26）。OSS-M4-3 完成后停止辅助工具扩张，OSS-M4-4 暂缓。本节只排定顺序，**不改变 §2 任何条目的批准状态**；每一项开工都需要单独的施工任务书。

1. **Release Composition 迁移**（V1-15 的 LR-15 组合阶段，即 §4.2 第 7 项的前半）。
   - 来源：私有 Draft #115 的实现提交（不含其私有 LR-14 登记），以作者信息已去除的 `git diff` 补丁形式在仓库外保存。
   - 涉及 8 个文件：`installer/scripts/build-router-release-composition.ps1`、`router-composition-verify.ps1`、`router-release-composition.psm1`、`router-install-ownership.psm1`，`tests/validate-router-release-composition.ps1`、`tests/validate-repo.ps1`，`docs/ROUTER_RELEASE_COMPOSITION.md`、`docs/LOCAL_ROUTER_RUNTIME_ROADMAP.md`。
   - 做法：作为普通 PR 在当时最新的 `main` 上重新应用：一个实现提交，加一个只追加 LR-14 登记的提交（`Base`/`Tip` 使用本仓库 SHA）。不导入任何私有提交、作者或基于私有 SHA 的授权。
   - 验证：涉及 installer 与 `validate-repo.ps1`，分级验证工具会要求 L3；另有 `validate-router-release-composition.ps1` 与 PR6 / PR7 回归；GitHub Development Gate 必须通过。
   - 2026-11-26 只读核对：该补丁在 `main` `2edf8a7` 上通过 `git apply --check`。这不是施工，也不代表迁移后的验证结果。
2. **BIND1 迁移**（安装身份绑定，依赖第 1 项）。
   - 涉及 5 个文件：`installer/scripts/router-install-identity.psm1`、`tests/validate-router-install-identity.ps1`、`tests/validate-repo.ps1`、`docs/ROUTER_INSTALL_IDENTITY.md`、`docs/LOCAL_ROUTER_RUNTIME_ROADMAP.md`。
   - 做法与验证同第 1 项。它是 PR8 stopped lease 的前提（`ROUTER_HOST_LIFECYCLE.md` §BLOCKED 1）。
   - 补丁只能在第 1 项之上检查，尚未单独核对。
3. **安装、卸载、升级、回滚及其他剩余 V1 功能**：按 §4.2 第 7–10 项与真实 Git 逐项确定，每项一个任务书、一个 PR。
4. **全功能回归、安全验收、真实环境验证与 V1 发布审批**（M4 → M5，§3 的全部标准）。

迁移完成之前，不得在任何文档或报告中宣称 Release Composition 或 BIND1 已在本仓库实现。

## 5. V1 之后的版本路线（建议，未批准）

| 版本 | 主题 | 候选内容 |
|---|---|---|
| V1.1 | 稳定与体验 | 在 V1 基础历史记录之上的增强：历史高级查询、筛选、统计、通知（不重复建设 V1 的基础记录）；Health Check 覆盖 Router、更多诊断；修复 V1 已知限制 |
| V1.2 | Provider 扩展 | 新 Provider 适配器（逐个独立 PR）、目录自动更新流程改进 |
| V2 | Desktop 深度集成 | HS-1B 后续 slice、Desktop 同线程切换实机闭环；若 Codex 将来提供官方控制通道，重新评估 app-server 路径 |
| V2+ | 智能切换（需单独批准） | 价格/延迟感知建议（只建议、不自动切换）、多账户、团队配置 |

## 6. 候选与待确认功能（不在任何已批准版本中）

- OpenCodex 原生选择器模式（Draft #67）。
- Chat Completions 协议 / Anthropic Messages 协议适配（当前架构明确不做）。
- 主动额度/余额查询（当前设计明确不做主动探测）。
- 代码签名与自动更新渠道。
- 非 Windows 平台。
- 远程或多用户 Router。

## 7. 变更控制

- 本文件的任何范围变化（加入、移出、延期 V1 功能）都必须由老板批准，并在 PR 描述中写明批准来源。
- 合并本规划文档只表示“文档结构与审计事实被接受”，**不表示 §2 的任何 V1 条目已获批准**。批准状态以老板在后续明确记录（例如在 §2 中把“建议”改为“已批准”并注明日期与来源）为准。
- 开发工程师只能执行本文件中已批准且当前被指派的任务；发现新需求时，写入 §6 并报告，不得自行开工。
