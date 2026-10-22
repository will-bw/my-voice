# my-voice Goal 最终报告

完成日期：2026-09-19

> 历史验收记录：以下提交、远程状态和测试结果截至 2026-09-19；2026-10-22 的公开源码准备见根目录 NOTICE.md，后续修复见 BAILIAN_RECOVERY_FIX.md。

## 完成口径

检查点 A、B1、B2、B3、C、D 的产品实现、自动化测试、当前可执行的真实环境验证和文档收尾均已完成。用户确认目前没有 100 条个人录音，并明确接受把个人语料规模验证留作后续工作后结束本 Goal。

本报告不会把未执行的个人语料 A/B、正式 P50/P95、连续 100 次听写或 30 分钟间歇使用写成已完成结果。

## 已交付功能

- 固定 VoiceInk `cd1d96f182b03561f5ef66c6a91e511cd7409c4c` 上游快照、GPL-3.0 来源记录和本地差异说明。
- 独立 Bundle ID、Keychain、Application Support、模型目录、更新与 License 隔离，以及 Apple Development 稳定签名的本机构建流程。
- 百炼普通按量 Batch 与 Streaming Provider、地域/Workspace 配置、连接验证、错误分类、健康状态、脱敏日志和 Mock HTTP/WebSocket 测试。
- Streaming HUD partial、final 原子投递、session 隔离、取消、晚到事件处理、64 KB 精确背压和 `Streaming → Batch → SenseVoice Small` 分级回退。
- 规则型动态热词、App/URL/Mode/上下文信号、Top-K、显式协议权重、隐私拒绝列表和 Streaming/Batch 共享的不可变提示快照。
- 安全纠错学习的人工审核、四类决策、Undo/改回负反馈、置信度下降、规则停用和误学习门禁。
- 默认关闭的原始录音历史、7 天/1 GB 清理、活动会话保护、崩溃遗留清理、脱敏会话指标和诊断包导出。
- 至少 100 条语料、50 条实体标注的私有 JSONL 校验与汇总工具；支持 CER、实体 Recall/Precision、误吸附率、最终修改率、成功率、延迟和资源指标。

## 验证证据

- 53 个 Swift XCTest 全部通过；覆盖 Provider 协议、错误与取消、回退、迁移、动态提示、隐私、安全学习、历史、诊断、首次引导和背压。
- 4 个 Python 工具测试全部通过；覆盖语料规模、真实音频存在性、实体门槛、重复与无效结果、三实验臂完整性。
- Release 构建成功；`codesign --verify --deep --strict` 与 `make verify-local-isolation` 通过。
- 当前签名应用已启动，Bundle ID 为 `com.will.myvoice.VoiceInk`，TeamIdentifier 为 `22ABMXL88T`。
- SenseVoice Small、百炼 Streaming、百炼 Batch 均完成真人转写；TextEdit、Chrome、VS Code 完成跨应用投递。
- 故意中断 Streaming 后真实进入 Batch；同时中断 Streaming/Batch 后真实进入 SenseVoice Small。两次均只投递一个 final，焦点正确，对应会话临时 WAV 无残留。
- 最终仓库审计：无 Git 远程、无凭据样式字面量、无超过 10 MiB 的跟踪文件、无意外未提交文件；API Key 仍只存在本机 Keychain。

## 实测指标

| 项目 | 结果 |
|---|---|
| 录音服务就绪 | 20 次：P50 0.101 s，P95 0.106 s，最大 0.109 s |
| 30 分钟真实空闲 | CPU 平均 0.0228%、最大 0.7%；RSS 平均 132.0 MiB、最大约 135.0 MiB |
| Streaming 最新真人样本 | 首个可见非空文本 1.008 s；松键到 final 0.115 s；679/679 音频块发送、0 丢弃 |
| Streaming final tail 探索样本 | 0.065 / 0.261 / 0.082 / 0.115 s，n=4；不冒充正式 P95 |
| Batch 真人样本 | 4.282 s 音频；转写 0.845 s；总处理 0.861 s |
| Streaming→Batch 回退 | 8.181 s 音频；转写 1.025 s；总处理 1.066 s |
| Streaming→Batch→本地回退 | 5.015 s 音频；本地转写 0.156 s；总处理 0.173 s |

## 已知限制与后续验证

- 首字只有 1 个直接样本且为 1.008 s，高于需求中的 0.8 s P50 目标；单样本不能判断总体 P50 是否达标。
- 需要 100 条个人录音、人工真值、至少 50 条实体标注和最终修改文本后，才能执行无热词/全量词/动态词 A/B，并报告 CER、实体指标、误吸附率和最终修改率。
- SenseVoice Small 与 Whisper Large v3 Turbo Quantized 的同语料对照、VAD/超时/Top-K/评分权重冻结仍待上述数据。
- 连续 100 次个人短句成功率和 30 分钟间歇使用内存增长尚未执行。
- VS Code 真人样本把“项目”识别为“小鹏”；本地回退样本把“MyVoice”识别为“my voiceice”。链路通过不等于这些样本的准确率通过。
- 当前产物是本机 Apple Development 签名构建，没有公证，也不是公开发布包。

## 本地提交

```text
b235afd docs: establish product and development baseline
d99c4dd vendor: import VoiceInk cd1d96f snapshot
ab9dd37 chore: isolate local VoiceInk baseline
8c155c6 build: pin whisper dependency
5d83adf docs: record Xcode build blocker
27fd370 build: verify local app baseline
c4d1e36 build: use stable local signing identity
380d9c2 docs: record signed onboarding validation
d40a462 docs: complete checkpoint A validation
8eda565 feat: add Bailian provider infrastructure
b5d43bb feat: wire resilient streaming fallback chain
a8030f7 feat: add adaptive recognition hints
f9c108e feat: add safe correction learning
cf995ac feat: add private history and evaluation metrics
c0ae280 feat: close remaining local validation gaps
30a2d9f feat: align onboarding with Bailian fallback flow
1197e5a docs: align implementation status and completion audit
8afce3e fix: validate Bailian through streaming handshake
8a6de0a docs: record real Bailian transcription checks
c5b74bc fix: harden real Bailian failover path
c0d85c1 feat: measure visible streaming latency
b529bb6 docs: align live verification status
HEAD docs: finalize accepted goal completion
```

`HEAD` 表示包含本报告的最终收尾提交。仓库保持本地 `main`，未配置远程、未 push、未创建 PR、未发布或公证。
