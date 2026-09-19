# my-voice 开发进度

- 当前检查点：A（VoiceInk 上游基线）
- 状态：进行中；Release 构建与启动已通过，等待 Accessibility 与端到端听写交互验收
- 更新日期：2026-09-19

## 已完成

- 完整阅读 README、需求 v0.2、开发设计 v0.1 和目标文件。
- 检查初始 Git 状态；仓库无历史、无远程，只有三份未跟踪基线文档。
- 建立需求与设计首个本地基线提交：`b235afd`。
- 从官方仓库导入固定 VoiceInk 提交 `cd1d96f182b03561f5ef66c6a91e511cd7409c4c`，逐文件校验 465 个 blob 一致。
- 建立纯上游快照提交：`d99c4dd`。
- 保留 GPL-3.0 `LICENSE`，并在 `UPSTREAM.md` 记录来源、SHA、日期、构建方式和本地差异。
- 已实现并验证本地构建的应用名、Bundle ID、Keychain、Application Support、自动更新和商业 License 隔离。
- 已核对 SwiftPM 锁文件；将上游 Makefile 的浮动 `whisper.cpp` 拉取固定为官方提交 `da545722…`，并增加来源、脏工作区和 framework revision 校验。
- 安装 CMake 4.4.3 与 Xcode Metal Toolchain 17F109；固定 whisper XCFramework 已成功生成。
- `make local` Release 构建成功，生成 `dist/my-voice.app`；应用已在当前 Mac 启动并进入权限引导页。
- 在 Onboarding 模型下载中发现 FluidAudio 默认共享官方缓存路径；已改为本地构建专属的 `com.will.myvoice/FluidAudio/Models`，并完成第二次 Release 构建。

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
| `xcodebuild -version`（恢复后） | Xcode 26.6（Build 17F113） |
| `xcodebuild -checkFirstLaunchStatus` | 通过（退出码 0） |
| `cmake --version` | CMake 4.4.3 |
| `xcrun metal --version` | Apple Metal 32023.883；Metal Toolchain 17F109 |
| `make check`（补齐 CMake/Metal 检查后） | 通过 |
| `make verify-local-isolation` | 通过：更新、License、Bundle ID、Keychain、Application Support 与输出路径隔离检查全部通过 |
| 临时 Git checkout 精确 fetch `da545722…` | 通过：HEAD、来源 URL 和提交时间与固定记录一致 |
| 在 `/Applications`、`~/Applications`、`~/Downloads`、桌面范围查找 Xcode | 未发现 `Xcode.app`、XIP 或 DMG |
| `make local` | 通过：`** BUILD SUCCEEDED **`；产物复制到 `dist/my-voice.app` |
| whisper revision marker | `da54572229bcf64ba367d96c7ef15770376c4280` |
| `codesign --verify --deep --strict` | 通过；ad-hoc `Sign to Run Locally`，无 TeamIdentifier |
| 产物 Info.plist | Bundle ID `com.will.myvoice.VoiceInk`；显示名 `my-voice`；无 `SUFeedURL` |
| `open dist/my-voice.app` / `pgrep` | 启动成功；进程持续运行，权限引导页可见 |
| 首次构建的退出/重启 | 麦克风与 Accessibility 均保持授权，“继续”可用 |
| 隔离修复后的第二次 `make local` | 通过：`** BUILD SUCCEEDED **`；完整检查与深度签名验证再次通过 |
| 专属数据目录 | 已创建 `~/Library/Application Support/com.will.myvoice`；数据库、录音和模型路径与官方 VoiceInk 隔离 |
| 新 ad-hoc 二进制权限状态 | 麦克风仍已授权；Accessibility 需对重建后的二进制重新授权 |
| 运行期网络观察 | 空闲/权限页无网络 socket；模型下载阶段仅连接本机代理，未发现官方更新或 License 连接 |

上游快照包含原有尾随空格，`git diff --cached --check` 会报告这些既有格式问题；为保持固定快照逐 blob 一致，导入提交未格式化上游文件。

## 剩余工作

- 由用户为最终重建产物在 macOS 系统设置中重新授权 Accessibility；随后重启并复核权限保持稳定。
- 在当前 Mac 完成全局快捷键、焦点恢复、跨应用文本投递和 SenseVoice Small 的真实验证。
- 运行期间复核不会连接官方更新/License 服务，并确认本地数据目录在完成 Onboarding 后与官方 VoiceInk 隔离。
- 检查点 A 验收通过后再开始 B1，并在实现当天重新核对百炼官方 Streaming、Batch、即时热词和上下文协议。

## 已解除阻塞

- 2026-09-19 已安装并选中 `/Applications/Xcode.app/Contents/Developer`；Xcode 首次启动组件和 `make check` 均通过。

## 当前需交互验证

- 应用权限页显示麦克风已授权；因 ad-hoc 重建使代码身份变化，Accessibility 必须由用户为最终产物在系统设置中重新授权。
- 授权后仍需完成全局快捷键、跨应用投递和 SenseVoice Small 的真实验证，检查点 A 尚未验收完成。
- 首次 Parakeet 下载被隔离审计主动停止；共享 `~/Library/Application Support/FluidAudio` 中约 13 MB 的部分下载未自动删除，避免误删既有用户数据。
