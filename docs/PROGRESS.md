# my-voice 开发进度

- 当前检查点：C（安全纠错学习）；A 已验收，B1/B2/B3 真实百炼验收待凭证与个人语料
- 状态：B3 非凭证实现、测试、签名 Release、设置页和真实旧 store 启动迁移均已通过；开始复核并扩展 Auto Learn
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
- 通过 Xcode Personal Team 创建 Apple Development 证书，补齐 Apple WWDR G3 中间证书，并修复 `LocalBuild.xcconfig` 对上游 SDK 条件签名设置的覆盖；`make local` 现可使用稳定签名身份。
- 稳定签名产物启动后，麦克风与 Accessibility 均显示已授权；完成 Parakeet V3 首次下载与应用内校验，模型仅写入本地隔离目录。
- Onboarding 已设置全局快捷键为 `Control + Option + Space` 并完成真人语音验收。
- 完成 Onboarding 真人英文听写；Parakeet V3 实际输出 `Please share the meeting notes before lounge.`，相对目标句把 `lunch` 识别为 `lounge`，链路成功但保留该识别误差证据。
- 下载并将默认 Dictation 模式切换为 SenseVoice Small；在 TextEdit 中完成真人中文跨应用听写，目标与实际输出均为“今天下午3点提交项目报告。”。
- 新增 `AdaptiveTermMetadata` 本地侧表及幂等迁移；现有词库实体不改动，重复规范化词只报告、不静默合并，旧词库 store 的增量迁移测试通过。
- 新增规则型 `HotwordSelector`，覆盖 App、URL、Mode、字面命中、固定、最近/频率、纠错和正负反馈；动态路径默认 Top 50，候选不足不补齐。
- 新增 `ContextPrivacyPolicy`：安全输入和无法确认的焦点边界强制阻止内容读取；用户 App/URL 拒绝列表初始为空并可在百炼设置页管理。
- 选中文本、剪贴板和屏幕文本只在对应 Mode 开启且隐私检查通过时本地抽取短原词；请求上下文硬限制 400 字符，不保存或记录原文。
- Streaming 与 Batch 回退共享同一份不可变 `RecognitionHintSnapshot`；设置页提供无热词、全量词（仅评测）和动态 Top-K 三种确定性路径。
- HUD 在百炼请求建立前显示仅含上下文来源类型和热词数量的临时摘要；partial 到达后切换为实时文本，摘要不含原词、上下文正文或热词列表。

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
| `security find-identity -v -p codesigning` | 通过：识别 1 个有效 Apple Development 身份 |
| 稳定签名 `make local LOCAL_CODESIGN_IDENTITY=…` | 通过：`** BUILD SUCCEEDED **`；主 App、XPC 与嵌套代码使用 Apple Development 身份 |
| `codesign --verify --deep --strict --verbose=4 dist/my-voice.app` | 通过；TeamIdentifier `22ABMXL88T`，指定要求基于 Apple 证书链与 Bundle ID，不再绑定 cdhash |
| `spctl --assess --type execute` | 拒绝；符合未公证 Apple Development 本机开发构建的预期，不作为发布包 |
| 稳定签名产物权限页 | 麦克风与 Accessibility 均显示“已授权”，“继续”可用 |
| Parakeet V3 首次下载 | 通过：约 494 MB，应用显示“已下载”；文件位于 `~/Library/Application Support/com.will.myvoice/FluidAudio/Models` |
| 下载期间网络观察 | VoiceInk 仅连接本机代理 `127.0.0.1:7890`；未观察到官方更新或 License 端点 |
| SenseVoice Small 下载与选择 | 通过：最终 GGUF 约 241 MB，无 `.partial` 残留；默认 Dictation 模式显示 SenseVoice Small |
| SenseVoice 真人中文听写 | 通过：历史状态 `completed`，实际 Provider/模型为 SenseVoice Small，输出“今天下午3点提交项目报告。” |
| SenseVoice 实测耗时 | 两次样本音频 5.068 s / 3.729 s；转写耗时 1.573 s / 0.044 s（第二次受已加载模型缓存影响） |
| TextEdit 跨应用投递 | 通过：截图可见完整中文结果，焦点与粘贴投递正确 |
| `xcodebuild test … -only-testing:VoiceInkTests`（B1/B2/B3） | 通过：30 个 XCTest；覆盖百炼协议、三级回退、共享提示快照、规则选择、隐私策略、HUD 脱敏摘要和旧 store 迁移 |
| B3 增量 Release 构建 | 通过：Apple Development 稳定签名；仅有上游既有警告 |
| B3 产物深度签名校验 | 通过：Bundle ID `com.will.myvoice.VoiceInk`，TeamIdentifier `22ABMXL88T` |
| 百炼设置页真实 UI | 通过：三种 Hotword comparison path、App/URL 拒绝列表与脱敏说明均可见 |
| 真实 `dictionary.store` 启动迁移 | 通过：迁移前后 `VocabularyWord=0`，新增侧表 `ZADAPTIVETERMMETADATA`，日志 `created=0 duplicates=0 orphans=0`；原 store 已先备份 |

上游快照包含原有尾随空格，`git diff --cached --check` 会报告这些既有格式问题；为保持固定快照逐 blob 一致，导入提交未格式化上游文件。

## 检查点 A 验收结论

- 固定上游、来源记录、本地隔离、真实 Release 构建与启动均通过。
- 麦克风、Accessibility、全局快捷键、TextEdit 文本投递和 SenseVoice Small 真人中文听写均通过。
- 本地数据、模型、Keychain 与官方 VoiceInk 隔离；运行期间未观察到官方更新或 License 连接。
- Apple Development 稳定签名已通过深度验证；指定要求不再绑定每次变化的 cdhash。

## B1 下一步

- 已在 2026-09-19 通过阿里云官方文档重新核对 Streaming、Batch、即时热词、上下文和业务空间专属端点协议。
- 已实现普通按量百炼凭证、地域、Workspace ID 与端点配置；API Key 使用不可同步的 macOS Keychain 项。
- 已新增 Batch/Streaming Provider、连接验证、错误分类、Provider Health、脱敏日志和 Mock HTTP/WebSocket XCTest。
- Mock 测试覆盖正常流程、乱序、重复、空 final、`task-failed`、断线、超时、401/403/429/5xx 与取消竞争；14 个测试通过。
- B1 代码已通过 Apple Development 稳定签名的 Release 构建与深度签名验证。
- 下一步：用户在应用内提供同地域的 Workspace ID 与普通按量 API Key 后，执行少量 Batch/Streaming 真人音频端到端验收；真实 Key 不进入仓库或测试夹具。

## B2 进展

- Streaming 录音停止时会等待后台连接启动结束；连接、发送或队列背压失败后使用完整录音文件回退，不投递截断的流式结果。
- 已实现百炼 `Streaming → Batch → SenseVoice Small` 分级回退；只有本机已安装 SenseVoice Small 时才启用本地第三级。
- 用户取消、无有效语音和完整录音文件缺失不会错误触发 Batch 或本地回退。
- HUD 继续只显示 partial；目标输入框仍只接收完整 final。累积 committed 事件会合并，不重复拼接到 HUD。
- 每次完成结果保存实际识别路径和实际模型；Batch/本地回退会显示明确通知，History Info 可查看 Recognition Path。
- Provider Health 在进程内共享；已知无效凭证或配置不会反复发起网络请求，配置或 API Key 改变时重置。
- B1/B2 Mock XCTest 共 21 个，新增覆盖 Streaming 成功、Batch 回退、本地回退、取消禁止回退、无语音禁止回退和累积 committed 合并。
- 待真实凭证：百炼 Streaming partial/final、Batch 固定音频、TextEdit/浏览器/代码编辑器 final 投递与真实回退验收。

## B3 进展

- 完整个人词库继续保存在本机；新侧表保存启用/固定、用户权重、App/URL/Mode 标签、使用/纠错/正负反馈和最近使用信号。
- 启动迁移幂等创建缺失元数据；不会因迁移失败重建数据库。空库、内存库和已有 `VocabularyWord` 落盘 store 均有测试覆盖。
- 动态选择只使用规则评分，不包含 Embedding、向量数据库或本地 LLM；默认发送最多 50 个词，稳定限制为 30～80。
- 默认权重 4；充分正反馈可升为 5；50 只接受用户显式权重。负反馈和停用状态会抑制自动选择。
- 安全控件、无法确认的 Accessibility 焦点、App 拒绝列表和 URL 拒绝列表会在读取正文前阻断；只保留来源类型和数量审计。
- `none` / `all` / `dynamic` 三种路径可在百炼设置页重复切换；具体协议和测试方法见 `docs/B3_RECOGNITION_HINTS.md`。
- 请求建立前的 HUD 会说明本次上下文来源类型和热词数量；该摘要仅存在于当前录音状态且已有不泄露正文/词条的专项测试。
- 当前 Mac 的本地真实 store 已完成原地增量迁移并重新启动；备份位于 `~/Library/Application Support/com.will.myvoice/MigrationBackups/B3-20260919-1614`。
- 待真实凭证与个人语料：固定音频的无热词/全量词/动态词 A/B，以及 Streaming/Batch 的真实准确率和误吸附对比。

## 已解除阻塞

- 2026-09-19 已安装并选中 `/Applications/Xcode.app/Contents/Developer`；Xcode 首次启动组件和 `make check` 均通过。

## 后续需交互验证

- 后续代码变更使用同一 Apple Development 身份重建后，复核麦克风与 Accessibility 授权保持稳定。
- B2 需要继续覆盖浏览器与代码编辑器的真实跨应用 Streaming/final 投递；本次 A 已完成 TextEdit 基线路径。
- 首次 Parakeet 下载被隔离审计主动停止；共享 `~/Library/Application Support/FluidAudio` 中约 13 MB 的部分下载未自动删除，避免误删既有用户数据。
