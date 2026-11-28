# Documentation

## Authoritative project documents

Each piece of information is maintained in one place only. Other documents link to it.

| Topic | Document |
|---|---|
| Safety floor, development and CI gates | [../AGENTS.md](../AGENTS.md) |
| Roles, session start/resume, verification levels, LR-14 registration, handoff | [../CLAUDE.md](../CLAUDE.md) |
| Product goals (final product) | [PRODUCT_VISION.md](PRODUCT_VISION.md) |
| Roadmap, V1 scope, locked work order | [MASTER_ROADMAP.md](MASTER_ROADMAP.md) |
| Current state, next scheduled task, open risks | [PROJECT_STATUS.md](PROJECT_STATUS.md) |
| Contributing and slice registration | [../CONTRIBUTING.md](../CONTRIBUTING.md) |
| Verification and workflow tools | [../tools/oss-workflow/README.md](../tools/oss-workflow/README.md) |
| Open-source history and genesis mode | [OSS_GENESIS.md](OSS_GENESIS.md) |

## Local Router

- `LOCAL_ROUTER_RUNTIME_ARCHITECTURE.md` — optional Local Router Mode architecture, component/security boundaries, state machines, compatibility, and build order.
- `LOCAL_ROUTER_RUNTIME_CONTRACTS.md` — canonical Responses ingress, entities/schemas, adapter, policy, secret, observability, pricing, and lifecycle contracts.
- `LOCAL_ROUTER_RUNTIME_ROADMAP.md` — independently reviewable LR build slices with readiness, tests, rollback, release gates, and PR boundaries (sub-roadmap of `MASTER_ROADMAP.md`).
- `ROUTER_HOST_RELEASE.md`, `ROUTER_HOST_STARTUP_GATE.md`, `ROUTER_HOST_LIFECYCLE.md`, `ROUTER_INSTALL_OWNERSHIP.md`, `ROUTER_SAFE_UNINSTALL.md` — LR-15 components.
- `HS1B_ROUTER_THREAD_MODEL_OVERRIDE_DESIGN.md`, `HS1C_QUOTA_EXHAUSTION_STICKY_FAILOVER.md` — thread-scoped model selection and quota-exhaustion failover.

## Research

- `CHATGPT_SUBSCRIPTION_QUOTA_FAILOVER_FEASIBILITY.md`, `CLI_REMOTE_TUI_INTEGRATION_VALIDATION.md` — M1 feasibility research for ChatGPT subscription quota failover.
- `HOT_SWITCH_FEASIBILITY_GATE.md` — Codex CLI / Desktop hot-switch platform limits.

## Direct Mode manager and earlier versions

- `README_中文.txt` — Chinese usage guide.
- `README_V3_升级说明.txt` — V3 model-discovery and approval workflow.
- `V3_架构.md` — V3 architecture.
- `主流模型_Codex_API配置参考.md` — provider/API compatibility reference.
