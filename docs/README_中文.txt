Codex Multi-Model Manager V3.3
===============================

用途
----
把 Windows 上的 Codex 做成：

GPT-5.6（第一优先）
  ↓ 额度不足/暂不可用
MiMo / Qwen / DeepSeek V4 / Grok / Groq / OpenRouter 备用
  ↓ GPT 额度恢复
安全切回 GPT-5.6

同时管理未来的新模型，以及 Ox Alpha 这类“先匿名、后揭晓/改名”的 stealth 模型生命周期。

重要：切模型不是换项目。项目目录、Git 仓库、未提交代码不会因为“选择另一个模型”而自动变化。

仓库结构
--------
skill\
  codex-multimodel-manager\
    SKILL.md
    scripts\
    references\

installer\
  ONE_CLICK_SETUP.cmd
  CODEX_MODEL_SWITCHER.cmd
  MODEL_UPDATE_CENTER.cmd
  CHECK_NEW_MODELS.cmd
  STEALTH_MODEL_REGISTRY.cmd
  LAUNCH_OX_ALPHA_EXPERIMENTAL.cmd
  INSTALL_SKILL_ONLY.cmd
  ENABLE_WEEKLY_MODEL_CHECK.cmd
  DISABLE_WEEKLY_MODEL_CHECK.cmd
  setup.ps1
  install-skill.ps1
  scripts\

docs\
  README_中文.txt
  OX_ALPHA.md
  STEALTH_MODEL_REGISTRY.md
  README_V3_升级说明.txt
  V3_架构.md
  主流模型_Codex_API配置参考.md

最快使用
--------
1. 打开 installer 文件夹。
2. 双击 installer\ONE_CLICK_SETUP.cmd。
3. 在向导里只配置你有 API Key 的平台。
4. Key 只保存到 Windows 用户环境变量，不写入项目或 config.toml。
5. 配置完成后，用 installer\CODEX_MODEL_SWITCHER.cmd 切换模型。
6. 新模型发现与审批使用 installer\MODEL_UPDATE_CENTER.cmd。
7. 匿名模型揭晓/改名管理使用 installer\STEALTH_MODEL_REGISTRY.cmd。

只安装 Skill
------------
双击：
installer\INSTALL_SKILL_ONLY.cmd

它会把：
skill\codex-multimodel-manager\

复制到：
~\.codex\skills\codex-multimodel-manager\

安全设计
--------
- 不修改任何业务项目源代码。
- 不自动执行 git reset / git clean / git stash。
- 不覆盖你现有的 Codex Provider 配置。
- 每次改 Codex 配置前自动备份。
- API Key 只存 Windows 用户环境变量。
- 不打印 API Key。
- 模型切换前可保存 repo / branch / HEAD / git status hash。
- 模型切换后可执行 handoff 校验。
- 匿名模型消失时不会自动猜“它就是某某正式模型”。
- 匿名模型迁移必须先验证新 model ID，再由你输入 MIGRATE 确认。

V3 新模型机制
------------
普通新模型：
自动发现 -> 候选区 -> Responses 测试 -> Tool Calling 测试 -> 你确认 APPROVE -> 注册到 Codex。

匿名 / stealth 模型：
Alias -> 跟踪匿名 ID -> 自动检查是否还存在 -> 消失则标记待复核 -> 官方揭晓后验证新 ID -> 你输入 MIGRATE -> Alias 指向确认后的新 ID。

第一条 stealth 记录：
Ox Alpha -> stealth/ox-alpha

以后即使 Ox Alpha 被认领并换成正式 model ID，旧匿名 ID 也会保留在历史中；同一个 Ox Alpha 启动入口可以解析到你确认后的新 ID。

自动发现不会自动替换 GPT-5.6，也不会自动批准新模型或自动认领匿名模型。

运行状态
--------
普通模型状态：
~\.codex\multimodel-manager\

Stealth Registry：
~\.codex\multimodel-manager\stealth-models.json
~\.codex\multimodel-manager\stealth-model-history.jsonl

这些运行文件不会写进你的业务项目 Git 仓库。

为什么部分模型不原生直连
------------------------
最新版 Codex 自定义 Provider 按 Responses API 工作。只提供 Chat Completions 的原生接口不应硬塞进最新版 Codex，可使用支持 Responses 的网关/转换层，例如 OpenRouter。

详细 Provider 兼容性见：
docs\主流模型_Codex_API配置参考.md

Stealth 详细规则见：
docs\STEALTH_MODEL_REGISTRY.md

回滚
----
Codex 配置备份：
~\.codex\backups\

模型交接快照：
~\.codex\handoffs\

Manager 运行状态：
~\.codex\multimodel-manager\
