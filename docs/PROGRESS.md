# my-voice 开发进度

- 当前检查点：A（VoiceInk 上游基线）
- 状态：进行中，尚未通过构建与真实运行验收
- 更新日期：2026-09-19

## 已完成

- 完整阅读 README、需求 v0.2、开发设计 v0.1 和目标文件。
- 检查初始 Git 状态；仓库无历史、无远程，只有三份未跟踪基线文档。
- 建立需求与设计首个本地基线提交：`b235afd`。
- 从官方仓库导入固定 VoiceInk 提交 `cd1d96f182b03561f5ef66c6a91e511cd7409c4c`，逐文件校验 465 个 blob 一致。
- 建立纯上游快照提交：`d99c4dd`。
- 保留 GPL-3.0 `LICENSE`，并在 `UPSTREAM.md` 记录来源、SHA、日期、构建方式和本地差异。
- 已实现本地构建的应用名、Bundle ID、Keychain、Application Support、自动更新和商业 License 隔离；尚待 Xcode 编译验证。
- 已核对 SwiftPM 锁文件；将上游 Makefile 的浮动 `whisper.cpp` 拉取固定为官方提交 `da545722…`，并增加来源、脏工作区和 framework revision 校验。

## 验证命令与结果

| 命令 | 结果 |
|---|---|
| `git status --short --branch` | 基线提交前确认只有预期未跟踪文档；上游导入前工作区干净 |
| `git remote -v` | 无输出；未配置远程 |
| `git rev-parse` / `git show`（临时上游仓库） | 固定 SHA 精确匹配 `cd1d96f…` |
| 逐文件 `git hash-object` 对比上游树 | `checked=465 mismatches=0` |
| `shasum -a 256 LICENSE` | `ffc4047c35e2601b4eb76e810b06d5d9754104e8f0e9b057c8a885fb8c7d4776` |
| `sw_vers` / `uname -m` | macOS 26.6.2（25G83），arm64 |
| `swift --version` | Apple Swift 6.3.3 |
| `xcodebuild -version` | 失败：当前开发目录是 Command Line Tools，不是完整 Xcode |
| `make verify-local-isolation` | 通过：更新、License、Bundle ID、Keychain、Application Support 与输出路径隔离检查全部通过 |
| 临时 Git checkout 精确 fetch `da545722…` | 通过：HEAD、来源 URL 和提交时间与固定记录一致 |
| 在 `/Applications`、`~/Applications`、`~/Downloads`、桌面范围查找 Xcode | 未发现 `Xcode.app`、XIP 或 DMG |

上游快照包含原有尾随空格，`git diff --cached --check` 会报告这些既有格式问题；为保持固定快照逐 blob 一致，导入提交未格式化上游文件。

## 剩余工作

- 在完整 Xcode 可用后执行 `make check`、Swift Package 解析和 `make local`。
- 启动 `dist/my-voice.app`，验证不会连接官方更新/License 服务，且数据目录与官方 VoiceInk 隔离。
- 在当前 Mac 完成麦克风、Accessibility、全局快捷键、焦点恢复、文本投递和 SenseVoice Small 的真实验证。
- 记录 Xcode 版本、解析结果、构建耗时与运行证据。
- 检查点 A 验收通过后再开始 B1，并在实现当天重新核对百炼官方 Streaming、Batch、即时热词和上下文协议。

## 阻塞项

- 当前未安装或未选择完整 Xcode。`/usr/bin/xcodebuild` 存在，但活动开发目录为 `/Library/Developer/CommandLineTools`，无法构建 macOS App。
- 麦克风与 Accessibility 的最终授权和跨应用输入验证需要在构建产物可运行后于本机交互完成。
