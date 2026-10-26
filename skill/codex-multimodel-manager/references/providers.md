# Codex 主流大模型 API 配置参考（2026-08）

> 关键变化：最新版 Codex 的自定义 Provider 只接受 `wire_api = "responses"`。
> 旧教程中的 `wire_api = "chat"` 已不适用于最新版 Codex。

## 1. OpenAI GPT-5.6

### ChatGPT 登录（优先）
无需额外 API Key Provider。Manager profile：

```toml
[profiles.mm_gpt56_chatgpt]
model = "gpt-5.6"
model_provider = "openai"
model_reasoning_effort = "high"
```

### OpenAI API
```toml
[model_providers.mm_openai_api]
name = "OpenAI API"
base_url = "https://api.openai.com/v1"
env_key = "CODEX_OPENAI_API_KEY"
wire_api = "responses"

[profiles.mm_gpt56_api]
model = "gpt-5.6"
model_provider = "mm_openai_api"
model_reasoning_effort = "high"
```

可用家族：
- `gpt-5.6` → GPT-5.6 Sol
- `gpt-5.6-terra`
- `gpt-5.6-luna`

---

## 2. Xiaomi MiMo

按量：
`https://api.xiaomimimo.com/v1`

Token Plan：
`https://token-plan-cn.xiaomimimo.com/v1`

```toml
[model_providers.mm_mimo]
name = "Xiaomi MiMo"
base_url = "https://api.xiaomimimo.com/v1"
env_key = "MIMO_API_KEY"
wire_api = "responses"

[profiles.mm_mimo_v25_pro]
model = "mimo-v2.5-pro"
model_provider = "mm_mimo"
model_reasoning_effort = "high"
```

模型：
- `mimo-v2.5-pro`
- `mimo-v2.5`

---

## 3. Qwen / 阿里云百炼

最新版 Codex 只使用百炼中明确支持 Responses API 的模型。

按量北京业务空间：
`https://{WorkspaceId}.cn-beijing.maas.aliyuncs.com/compatible-mode/v1`

按量新加坡：
`https://{WorkspaceId}.ap-southeast-1.maas.aliyuncs.com/compatible-mode/v1`

Token Plan：
`https://token-plan.cn-beijing.maas.aliyuncs.com/compatible-mode/v1`

```toml
[model_providers.mm_modelstudio]
name = "Alibaba Model Studio Responses"
base_url = "https://{WorkspaceId}.cn-beijing.maas.aliyuncs.com/compatible-mode/v1"
env_key = "CODEX_DASHSCOPE_API_KEY"
wire_api = "responses"

[profiles.mm_qwen38_max]
model = "qwen3.8-max"
model_provider = "mm_modelstudio"
```

当前 Responses 支持列表包含（具体套餐权限另算）：
- `qwen3.8-max`
- `qwen3-coder-plus`
- `qwen3-coder-flash`
- `qwen3-coder-next`
- `deepseek-v4-flash`
- `deepseek-v4-pro`
- 以及百炼官方 Responses 页面列出的其他 Qwen 模型

注意：百炼 Coding Plan 官方 Codex 文档目前说明它仅支持 Chat/Completions，因此最新版 Codex 不直接配置该 Plan。

---

## 4. DeepSeek V4

### 原生 DeepSeek API
原生官方示例当前仍是：
`https://api.deepseek.com/chat/completions`

即 Chat Completions。最新版 Codex 已移除 `wire_api="chat"`，所以**不要把原生 DeepSeek 端点硬塞进最新版 Codex**。

### 推荐
A. 百炼 Responses：
- `deepseek-v4-pro`
- `deepseek-v4-flash`

B. OpenRouter Responses。

---

## 5. Kimi

Kimi 官方 Codex 文档明确说明：
- Codex → Responses API
- Kimi For Coding → Chat Completions
- 两者协议不兼容

官方文档给出的方案是经 CC Switch 本地路由转换；该路线属于社区第三方接入，Kimi 不负责维护。

另一种更统一的方案：OpenRouter Responses。

---

## 6. Claude

Anthropic 的 OpenAI SDK compatibility 官方示例使用：
`client.chat.completions.create(...)`

因此原生 OpenAI compatibility 不是最新版 Codex 所需的 Responses 协议。

推荐：
- OpenRouter Responses
- 或其他明确实现 OpenAI Responses 的可信网关

---

## 7. Gemini

Google 官方 OpenAI compatibility 当前示例端点：
`https://generativelanguage.googleapis.com/v1beta/openai/chat/completions`

属于 Chat Completions。

推荐：
- OpenRouter Responses
- 或未来 Google 官方若提供并确认兼容 `/responses` 后再直连

---

## 8. GLM

GLM Coding Plan 官方当前提供：
- Anthropic Messages
- OpenAI Chat Completion
  `https://open.bigmodel.cn/api/coding/paas/v4`

因此最新版 Codex 不直接用该原生 Coding 端点。

推荐：
- OpenRouter Responses
- 或经已经验证的 Responses 转换层

---

## 9. MiniMax

MiniMax 官方 OpenAI compatibility 当前接口：
`/v1/chat/completions`

因此最新版 Codex 不直接原生配置。

推荐：
- OpenRouter Responses
- 或可信 Responses bridge

---

## 10. xAI Grok

xAI 官方已经提供：
`POST https://api.x.ai/v1/responses`

可直接接最新版 Codex：

```toml
[model_providers.mm_xai]
name = "xAI Responses"
base_url = "https://api.x.ai/v1"
env_key = "XAI_API_KEY"
wire_api = "responses"

[profiles.mm_grok]
model = "grok-4.6"
model_provider = "mm_xai"
```

---

## 11. Groq

Groq 官方已提供 OpenAI-compatible Responses API：

```toml
[model_providers.mm_groq]
name = "Groq Responses"
base_url = "https://api.groq.com/openai/v1"
env_key = "GROQ_API_KEY"
wire_api = "responses"
```

模型 ID 以 Groq 控制台当前可用列表为准。

---

## 12. OpenRouter：通用多模型通道

```toml
[model_providers.mm_openrouter]
name = "OpenRouter Responses"
base_url = "https://openrouter.ai/api/v1"
env_key = "OPENROUTER_API_KEY"
wire_api = "responses"
```

启动指定模型：
```powershell
codex -m "provider/model-slug" -c 'model_provider="mm_openrouter"'
```

优点：
- 一把 Key 管很多模型
- 适合 Claude / Gemini / Kimi / GLM / MiniMax / DeepSeek 等备用
- 不需要为每家只支持 Chat Completions 的厂商降级 Codex

缺点：
- 多一层路由
- 费用、隐私、可用模型与路由策略要按 OpenRouter 当前规则确认

---

# 为什么本工具不自动降级 Codex

一些厂商官方教程仍建议老 Codex + `wire_api="chat"`。
本工具的原则是：
- 保持最新版 Codex
- 只接 Responses
- Chat-only 模型通过 Responses gateway/bridge
- 不为了某个备用模型破坏主力 GPT-5.6 工作流

# 代码安全

配置/切模型时：
- 不删除项目
- 不复制项目
- 不 reset/stash/clean
- 不覆盖未提交文件
- 不把 API Key 写入仓库
- 管理器只改 `~/.codex/config.toml` 的专属管理区
- 每次修改前备份
- 切模型前可保存 Git handoff，切换后验证 Repo/Branch/HEAD/status hash
