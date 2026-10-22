# 上游来源与本地差异

## 固定来源

- 项目：VoiceInk
- 仓库：https://github.com/Beingpax/VoiceInk
- 固定提交：`cd1d96f182b03561f5ef66c6a91e511cd7409c4c`
- 上游提交时间：2026-09-17T14:34:47+05:45
- 导入日期：2026-09-19
- 导入方式：在临时目录检出固定提交，再通过 `git archive` 将 465 个跟踪文件展开到当前仓库；未携带上游 `.git`。
- 校验：导入后逐文件执行 `git hash-object`，465 个 blob 与上游树全部一致。
- 许可证：GPL-3.0；根目录 `LICENSE` 于 2026-10-22 补齐为 GNU 官方完整文本，导入时的原始节选另存于 `licenses/VoiceInk-original-LICENSE.txt`。
- 导入时原始许可证节选的 SHA-256：`ffc4047c35e2601b4eb76e810b06d5d9754104e8f0e9b057c8a885fb8c7d4776`

纯上游快照对应本地提交 `d99c4dd`。需求与开发设计基线在其前一提交 `b235afd`，不会混入上游历史。

## 构建方式

目标环境为 macOS 14.4 及以上和完整 Xcode。当前本地入口：

```bash
make check
make local
open dist/my-voice.app
```

`make local` 使用 `LocalBuild.xcconfig`、`VoiceInk.local.entitlements` 和 `LOCAL_BUILD`/`MYVOICE_LOCAL_BUILD` 编译条件。构建产物、Derived Data 和外部模型/依赖不得提交。

SwiftPM 依赖由上游 `Package.resolved` 固定。上游 Makefile 原本会拉取浮动的 `whisper.cpp` 主分支；本项目将它固定为官方提交 `da54572229bcf64ba367d96c7ef15770376c4280`（2026-09-15），即 VoiceInk 固定提交之前最新的上游提交。构建脚本会验证来源、工作区状态和 framework revision 标记，不会对带有本地改动的外部 checkout 执行覆盖操作。

## 当前本地差异

检查点 A 在纯快照之后引入以下隔离改动：

1. 本地构建产物输出为 `dist/my-voice.app`，避免覆盖官方 `VoiceInk.app`。
2. 本地构建使用 `com.will.myvoice.*` Bundle ID、`com.will.myvoice` Keychain service 和 `com.will.myvoice` Application Support 目录，不读取或覆盖官方应用数据。
3. 删除官方 Sparkle feed 与签名元数据；`LOCAL_BUILD` 下更新检查入口为无操作，不能安装官方发布包。
4. `LOCAL_BUILD` 下商业 License 状态固定为本地可用，购买、验证和停用网络入口均被禁用，不调用 Polar 服务。
5. 保留本项目 `docs/`，并新增本文件与 `docs/PROGRESS.md`。

## 后续修改与验证记录

之后已接入百炼 Streaming/Batch、SenseVoice Small 回退、动态热词、安全纠错学习、隐私历史与评测工具，并修复百炼失败后的恢复问题和自定义 Qwen 润色参数。相关日期与摘要见 [NOTICE.md](NOTICE.md)。

早期未安装 Xcode 的阻塞记录已过时。后续构建与实测证据见 [最终报告](docs/FINAL_REPORT.md)、[百炼恢复修复记录](docs/BAILIAN_RECOVERY_FIX.md) 和 [开发进度](docs/PROGRESS.md)；这些是各记录日期的历史证据。

## 公开源码

2026-10-22 为 GitHub 公开源码准备补全 GPLv3 全文、修改声明和私有文件忽略规则。公开范围为源代码、构建脚本和文档；不包含本机签名证书、API Key、个人热词、私有语料、依赖检出或应用安装包。保留本地开发历史和上游快照来源。
