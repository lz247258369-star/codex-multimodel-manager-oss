Codex Multi-Model Manager V3
=============================

V3 新增：自动模型注册中心

V2：
- 多 Provider 一键配置
- 模型切换
- Git handoff

V3：
- 自动从已配置 Provider 的 /models 端点发现模型
- 第一次扫描自动建立“当前模型基线”
- 以后新出现的模型才标记为 NEW
- 新模型进入候选区，不会直接启用
- 可做基本 Responses 测试
- 可做 Tool Calling 测试
- 通过后由你确认批准
- 批准后自动写入 Codex profile
- 动态模型出现在模型切换器的“动态批准的新模型”
- 可选 Windows 每周自动检查
- 定时检查只访问模型列表，不跑付费推理，不自动修改配置

新版仓库结构
------------
skill\codex-multimodel-manager\
  真正安装到 Codex 的 Skill 本体。

installer\
  Windows 一键配置、模型切换、模型更新中心和运行脚本。

docs\
  中文说明、架构和 Provider 配置参考。

推荐使用步骤
------------
1. 打开 installer 文件夹。
2. 先运行 installer\ONE_CLICK_SETUP.cmd，配置你有 Key 的 Provider。
3. 双击 installer\CHECK_NEW_MODELS.cmd。
4. 第一次运行会建立基线，不会把当前模型都当“新品”。
5. 以后再运行时，只报告新增模型。
6. 有新品时，双击 installer\MODEL_UPDATE_CENTER.cmd。
7. 选择基本 Responses 测试。
8. 如果需要更高把握，再做 Tool Calling 测试。
9. 输入 APPROVE 后才注册到 Codex。
10. 用 installer\CODEX_MODEL_SWITCHER.cmd -> “动态批准的新模型”启动。

每周自动检查
------------
开启：
installer\ENABLE_WEEKLY_MODEL_CHECK.cmd

关闭：
installer\DISABLE_WEEKLY_MODEL_CHECK.cmd

默认每周日 10:00（电脑本机时间）。

定时任务只做“发现”，不会：
- 消耗模型推理额度
- 自动批准新模型
- 自动修改 Codex 配置
- 自动更换当前模型
- 修改任何项目代码

为什么不做“发现即自动启用”
--------------------------
因为：
- /models 里出现，不代表 /responses 可用
- /responses 可用，不代表工具调用适合 Codex
- 新版本不一定比旧版本更稳定
- 自动替换主力模型可能破坏开发连续性

所以 V3 采用：
自动发现 -> 测试 -> 你确认 -> 注册

代码安全
--------
V3 自己的运行状态写在 ~/.codex/，不会写进其他无关的业务 Git 项目。
