# my-voice 开发进度

- 当前检查点：A、B1、B2、B3、C、D 已完成；无个人语料条件下可执行的开发、测试、真实链路验收和文档收尾均已结束
- 状态：Goal 已按用户 2026-09-19 的明确决定完成；53 个 XCTest + 4 个 Python 工具测试通过，个人 100 条语料规模验证作为后续工作保留，不声称已经执行
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
- Auto Learn 新安装默认人工审核；新增本地 `CorrectionFeedbackMetadata`，把接受、拒绝、Undo、用户改回、置信度和停用状态连接到词库与动态热词信号。
- 纯标点/大小写风格变化、重复边界锚点和大范围整句重写不会生成永久规则；两次负反馈后具体替换变体停止应用。
- 原始录音历史默认关闭；用户可显式选择目录、保留天数和空间上限，默认按 7 天或 1 GB 任一先到从旧到新清理，并保护活动会话。
- 新增白名单化 `SessionDiagnosticMetric`，只保存 Provider、回退路径、阶段耗时、音频时长、热词数量、上下文类型和固定错误分类。
- 新增至少 100 条/50 条实体标注的 JSONL 评测校验与汇总工具，覆盖准确率、资源、网络、延迟和人工修改指标；私有语料与结果目录不进入 Git。
- Streaming 音频队列采用精确 64,000 字节（2 秒、16 kHz、PCM16 单声道）上限；溢出会结束流式会话并使用完整录音文件回退，不会继续发送截断音频。
- 百炼流式协议增加 task-start 前音频门禁、partial 修订和未知服务端字段兼容测试；协议违规会关闭连接并归类失败。
- App、URL host 与 Mode 排序信号默认开启且可独立关闭；命中的 Provider 原始结果只在本机更新使用频率与关联信号，不上传这些标签。
- 用户可在词库显式选择协议权重 1～5 或 50；自定义 App/URL 拒绝列表可整体暂停，但安全输入和未知焦点保护始终强制生效。
- 历史关闭时的会话音频改存应用专属临时目录；启动会清除崩溃遗留文件，真实启动清理已验证。
- 设置页新增可审阅的脱敏诊断包导出；仅包含白名单会话字段和环境版本，导出前再次收敛异常或被篡改的数据。
- 首次引导默认选择 Bailian Cloud Streaming，并要求地域、Workspace ID 与 Keychain API Key 一起验证；只有 Key、没有有效 Workspace 配置时不能继续，失败的连接测试不会持久化 Workspace 草稿。
- 修复真实设置页连接验证的 HTTP 400：旧实现向 Batch 发送 100 ms 全静音 WAV，百炼会将其判为静音或有效音频过短；现改为建立默认 Streaming 会话并等待 `task-started`，成功后立即关闭且不发送任何音频。新增成功/鉴权失败两条 Mock 回归测试，错误信息继续脱敏。
- 使用用户在应用内输入的北京地域 Workspace 与普通按量 API Key 完成真实 Streaming 握手验证；Workspace 写入应用配置，Key 只写入独立的本机 Keychain 项，仓库与诊断记录均不包含密钥。
- 在 TextEdit 中完成真人百炼 Streaming 与 Batch 各一次端到端验收；两次均一次性写入完整 final“今天下午3点提交MyVoice项目报告。”，无重复文本，实际 Provider 均为 Bailian，且未发生回退。验收后已恢复 Streaming 为默认 Dictation 模型。
- 完成 Chrome 与 VS Code 真人 Streaming 投递：Chrome 由用户确认完整显示“今天下午3点提交MyVoice项目报告。”；VS Code 焦点与单次 final 投递通过，但实际识别为“今天下午3点提交MyVoice小鹏报告。”，保留“项目”→“小鹏”误差证据。
- 使用进程级临时无法连接端点完成两级真实故障回退：单独中断 Streaming 时成功走 `batch-fallback`；同时中断 Streaming/Batch 时成功走 `local-fallback` 到 SenseVoice Small。两次均只投递一次，焦点正确，会话 WAV 均已清理；测试后删除临时端点并重启恢复默认 Streaming。
- 真实回退日志暴露了一次 SwiftData 主线程 `ModelContext` 被异步 Provider 访问的运行时告警。云端转写现优先复用已捕获的不可变词表快照；只有无快照的旧 Provider 路径才在 `MainActor` 读取词库，避免跨执行器使用主 context。
- Streaming 时序增加隐私安全的直接观测：只在首次向 HUD 发出非空文本时记录会话启动至首个可见文本的秒数与字符数，空 partial/commit 不再冒充首字；停止路径继续直接记录松键至 final 完成的 tail，不记录正文。
- 使用新仪器在 TextEdit 完成真人短句：实际一次写入“今天下午3点提交MyVoice项目报告。”，首个可见文本 1.008 s，松键到 final 0.115 s，679/679 音频块全部发送、0 丢弃；Provider `Bailian`、路径 `streaming`，7.214 s 音频，总处理 0.141 s。该首字单样本高于 0.8 s 目标，不能以一个样本推断 P50。
- 首次引导的本地模式和云端离线兜底统一为 SenseVoice Small；云端模式可跳过安装，但会明确说明离线识别和自动本地回退不可用。

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
| 百炼本地信号与隐私开关 UI | 通过：App、URL host、Mode 三个本地信号默认开启且可独立关闭；自定义拒绝列表暂停开关和强制安全边界说明可见；API Key 保持安全输入框 |
| 真实 `dictionary.store` 启动迁移 | 通过：迁移前后 `VocabularyWord=0`，新增侧表 `ZADAPTIVETERMMETADATA`，日志 `created=0 duplicates=0 orphans=0`；原 store 已先备份 |
| `xcodebuild test … -only-testing:VoiceInkTests`（C） | 通过：37 个 XCTest；新增 7 个安全学习测试，覆盖四类审核、迁移、门禁、Undo/拒绝/改回与停用 |
| C 增量 Release 构建与深度签名校验 | 通过：Apple Development 稳定签名；Bundle ID `com.will.myvoice.VoiceInk`，TeamIdentifier `22ABMXL88T` |
| C 真实 `dictionary.store` 启动迁移 | 通过：迁移前后 `WordReplacement=0`，新增 `ZCORRECTIONFEEDBACKMETADATA`，侧表记录 0；日志 `created=0 duplicates=0 orphans=0` |
| `xcodebuild test … -only-testing:VoiceInkTests`（本轮最终回归） | 通过：53 个 XCTest；覆盖首次引导策略、历史/诊断、动态提示、流式协议、无音频连接验证、三级回退和精确 64 KB 背压 |
| 百炼真实连接验证 | 通过：设置页显示“已验证/密钥已验证”，Streaming 与 Batch 模型均可用；Keychain 项与 Workspace 配置存在，未读取或输出 Key 内容 |
| 百炼 Streaming→TextEdit 真人短句 | 通过：7.246 s 音频，Streaming 转写阶段 0.065 s，总处理 0.113 s；实际 Provider `Bailian`、路径 `streaming`、无回退；完整 final 一次写入 |
| 百炼 Batch→TextEdit 真人短句 | 通过：4.282 s 音频，Batch 转写 0.845 s，总处理 0.861 s；实际 Provider `Bailian`、路径 `selected-model`、无回退；完整 final 一次写入 |
| 百炼 Streaming→Chrome 真人短句 | 通过：7.193 s 音频，转写 0.261 s，总处理 0.279 s；Provider `Bailian`、路径 `streaming`；因浏览器安全策略无法由自动化读取 `data:` 页面，完整文本由用户现场确认 |
| 百炼 Streaming→VS Code 真人短句 | 投递通过、识别有误：8.967 s 音频，转写 0.083 s，总处理 0.093 s；Provider `Bailian`、路径 `streaming`；一次写入“今天下午3点提交MyVoice小鹏报告。”，未把准确性误差记为通过 |
| 真实 Streaming→Batch 回退 | 通过：故意将 WebSocket 指向无法连接的本机端口；8.181 s 音频，Batch 转写 1.025 s，总处理 1.066 s；Provider `Bailian`、路径 `batch-fallback`，完整 final 一次写入 |
| 真实 Streaming→Batch→SenseVoice Small 回退 | 链路通过、识别有误：同时中断 WebSocket/HTTP；5.015 s 音频，本地转写 0.156 s，总处理 0.173 s；Provider `TranscribeCpp`、路径 `local-fallback`，一次写入“今天下午3点提交my voiceice项目报告。” |
| 回退恢复与临时音频清理 | 通过：两个临时高级端点键均已删除，签名应用已重启；两个会话 UUID 对应的 WAV 均无残留 |
| SwiftData 并发告警修复后完整回归 | 通过：53 个 XCTest 全部成功；修复不改变 Streaming/Batch 共享的 `RecognitionHintSnapshot` |
| 修复后稳定签名 Release | 通过：`make local`、`codesign --verify --deep --strict`、`make verify-local-isolation`均成功；Bundle ID `com.will.myvoice.VoiceInk`、TeamIdentifier `22ABMXL88T`，新产物已启动且 Dictation 仍为 Bailian Streaming |
| Streaming 直接时序仪器化后完整回归 | 通过：53 个 XCTest 全部成功；Release 构建、深度签名与本地隔离校验通过，新产物已启动且 Dictation 仍为 Bailian Streaming |
| Streaming→TextEdit 首字/final tail 真人短句 | 识别与投递通过：首个可见非空文本 1.008 s、松键到 final 0.115 s；7.214 s 音频，Streaming 转写 0.116 s、总处理 0.141 s；Provider `Bailian`、路径 `streaming`，679/679 音频块发送、0 丢弃，完整 final 一次写入 |
| `PYTHONDONTWRITEBYTECODE=1 python -m unittest scripts.tests.test_evaluate_corpus` | 通过：4 个工具测试；验证真实音频、100 条/50 条实体门槛、重复/空成功结果/无效数值拒绝，以及同 Provider 三实验臂完整覆盖门槛 |
| D `make local` | 通过：`** BUILD SUCCEEDED **`；Apple Development 稳定签名 Release 产物启动成功 |
| D 真实 store 启动迁移 | 通过：新增 `ZSESSIONDIAGNOSTICMETRIC`，迁移后初始记录 0；三类 store 已备份到 `MigrationBackups/D-20260919-163812` |
| Recording History 真实 UI | 首次为 off；开启后显示保存目录、7 天、1 GB、立即清理和清空；关闭时可选保留或删除已有录音 |
| 默认关闭真实短录音 | 通过：约 1.987 秒本地录音前后目录文件数 5→5；临时音频已删除，诊断侧表成功写入脱敏记录 |
| `scripts/measure_runtime.sh` / `footprint` | 新鲜启动空闲 CPU 0.0%，物理占用 57 MB、Energy Impact 0.0；一次本地识别后稳定为 CPU 0.1%、物理占用 86 MB、Energy Impact 0.1 |
| 空闲网络 10 秒差值 | 0 B 入 / 0 B 出；进程存在到本机代理的空闲连接，但采样窗口无流量 |
| 进程启动采样 | `open -n` 到 PID 可见 0.077 秒；仅代表进程创建，不冒充完整 UI 就绪时间 |
| 录音服务就绪冷启动采样 | 20 次独立重启：平均 0.099 秒，P50 0.101 秒，P95 0.106 秒，最大 0.109 秒；由应用初始化完成后的生命周期日志测量 |
| 30 分钟真实空闲采样 | 360 次、间隔 5 秒：平均 CPU 0.0228%，最大 0.7%；平均 RSS 132.0 MiB，最大约 135.0 MiB；最终 footprint 46 MB、峰值 69 MB |
| 崩溃遗留临时音频清理 | 通过：预置应用专属临时 WAV 后启动签名 Release，文件在初始化时被删除 |
| 脱敏诊断包真实 UI | 通过：点击后先显示明确 Includes/Excludes 清单；取消后未生成文件，未读取或修改凭据 |
| 首次引导真实 UI | 通过：默认 Bailian Cloud streaming；地域、Workspace 和安全 Key 输入可见；未提供 Key 时测试/继续禁用；SenseVoice 离线兜底与三级回退说明可见。使用进程级临时启动参数验收，未重置用户设置 |

上游快照包含原有尾随空格，`git diff --cached --check` 会报告这些既有格式问题；为保持固定快照逐 blob 一致，导入提交未格式化上游文件。

## 检查点 A 验收结论

- 固定上游、来源记录、本地隔离、真实 Release 构建与启动均通过。
- 麦克风、Accessibility、全局快捷键、TextEdit 文本投递和 SenseVoice Small 真人中文听写均通过。
- 本地数据、模型、Keychain 与官方 VoiceInk 隔离；运行期间未观察到官方更新或 License 连接。
- Apple Development 稳定签名已通过深度验证；指定要求不再绑定每次变化的 cdhash。

## B1 验收结论

- 已在 2026-09-19 通过阿里云官方文档重新核对 Streaming、Batch、即时热词、上下文和业务空间专属端点协议。
- 已实现普通按量百炼凭证、地域、Workspace ID 与端点配置；API Key 使用不可同步的 macOS Keychain 项。
- 已新增 Batch/Streaming Provider、连接验证、错误分类、Provider Health、脱敏日志和 Mock HTTP/WebSocket XCTest。
- Mock 测试覆盖正常流程、乱序、重复、空 final、`task-failed`、断线、超时、401/403/429/5xx 与取消竞争；14 个测试通过。
- B1 代码已通过 Apple Development 稳定签名的 Release 构建与深度签名验证。
- 北京地域 Workspace 与普通按量 API Key 已在应用内完成真实 Streaming 握手；真实 Key 只在 Keychain 中，未进入仓库、测试夹具或日志。
- Streaming 与 Batch 真人短句均在 TextEdit 完成端到端转写与 final 投递，基础云端 Provider 验收通过。

## B2 进展

- Streaming 录音停止时会等待后台连接启动结束；连接、发送或队列背压失败后使用完整录音文件回退，不投递截断的流式结果。
- 内存中的 Streaming 音频队列按字节精确限制为 64,000 字节；生产者不阻塞录音线程，消费者释放预算，完成时先排空既有片段，溢出时立即进入完整文件回退。
- 已实现百炼 `Streaming → Batch → SenseVoice Small` 分级回退；只有本机已安装 SenseVoice Small 时才启用本地第三级。
- 用户取消、无有效语音和完整录音文件缺失不会错误触发 Batch 或本地回退。
- HUD 继续只显示 partial；目标输入框仍只接收完整 final。累积 committed 事件会合并，不重复拼接到 HUD。
- 每次完成结果保存实际识别路径和实际模型；Batch/本地回退会显示明确通知，History Info 可查看 Recognition Path。
- Provider Health 在进程内共享；已知无效凭证或配置不会反复发起网络请求，配置或 API Key 改变时重置。
- B1/B2 Mock XCTest 共 21 个，新增覆盖 Streaming 成功、Batch 回退、本地回退、取消禁止回退、无语音禁止回退和累积 committed 合并。
- 已完成 TextEdit、Chrome 与 VS Code 真实 Streaming/final 投递，以及 `Streaming → Batch → SenseVoice Small` 两级真实故障回退。目标输入框只接收一次 final，回退后无会话 WAV 残留。
- HUD 首个可见非空文本和松键到 final 已建立直接时间戳：最新真人样本分别为 1.008 s 与 0.115 s；此前三个真人 Streaming 会话的 final tail 为 0.065/0.261/0.082 s。现有 tail 探索样本范围为 0.065～0.261 s（n=4），仍不能代替个人语料上的正式 P50/P95。

## B3 进展

- 完整个人词库继续保存在本机；新侧表保存启用/固定、用户权重、App/URL/Mode 标签、使用/纠错/正负反馈和最近使用信号。
- 启动迁移幂等创建缺失元数据；不会因迁移失败重建数据库。空库、内存库和已有 `VocabularyWord` 落盘 store 均有测试覆盖。
- 动态选择只使用规则评分，不包含 Embedding、向量数据库或本地 LLM；默认发送最多 50 个词，稳定限制为 30～80。
- 默认权重 4；充分正反馈可升为 5；50 只接受用户显式权重。负反馈和停用状态会抑制自动选择。
- 安全控件、无法确认的 Accessibility 焦点、App 拒绝列表和 URL 拒绝列表会在读取正文前阻断；只保留来源类型和数量审计。
- `none` / `all` / `dynamic` 三种路径可在百炼设置页重复切换；具体协议和测试方法见 `docs/B3_RECOGNITION_HINTS.md`。
- 请求建立前的 HUD 会说明本次上下文来源类型和热词数量；该摘要仅存在于当前录音状态且已有不泄露正文/词条的专项测试。
- App、URL host 和 Mode 本地排序信号默认开启、可独立关闭；原始 Provider 文本命中本次已选词后才在本机记录使用信号。词库界面支持 Auto、1～5 和显式 50 权重。
- 自定义 App/URL 拒绝列表可整体暂停；安全输入控件和无法确认的焦点边界不受该开关影响，始终禁止读取内容。
- 当前 Mac 的本地真实 store 已完成原地增量迁移并重新启动；备份位于 `~/Library/Application Support/com.will.myvoice/MigrationBackups/B3-20260919-1614`。
- 待真实个人语料：固定音频的无热词/全量词/动态词 A/B，以及 Streaming/Batch 的个人语料准确率和误吸附对比；百炼凭证和基础真人链路已经验证。

## C 进展

- 复用既有 Auto Learn 的目标控件、投递范围、焦点和 60 秒观察窗口；范围锚点不唯一时放弃，不扩大为全局输入监听。
- 新安装默认 `Manually`：AI 只生成建议，人工审核面板区分“替换+词库、仅替换、仅词库、拒绝”，不会默认静默批准永久规则。
- 新增 `CorrectionFeedbackMetadata` 唯一侧表和幂等迁移，保存接受、拒绝、Undo、改回、置信度与启用状态，并同步目标词的自适应正负反馈。
- Dismiss、Undo 和精确用户改回都会降置信度；累计两次负反馈后，`WordReplacementService` 停用对应的具体来源/目标变体。
- 确定性门禁拒绝纯标点、大小写/变音符号风格变化、只增删内容、重复锚点和超过 6 个词的整段重写；详细设计见 `docs/C_SAFE_LEARNING.md`。
- 37 个 XCTest 全部通过，其中 7 个 C 专项测试覆盖四类审核、侧表迁移、局部纠错保留、误学习过滤和规则停用。
- 当前 Mac 的真实 store 已备份到 `~/Library/Application Support/com.will.myvoice/MigrationBackups/C-20260919-162603` 后原地迁移；可见规则数量保持为 0，侧表创建成功，签名应用已重新启动。
- SenseVoice Small 继续作为默认本地模型；与 Whisper Large v3 Turbo Quantized 的同语料对照等待个人真实语料和对应模型结果，不据主观判断改默认值。

## D 进展

- `Save Recording History` 默认关闭；完成、失败或取消后删除临时音频并清空转写记录中的音频地址。开启后可选目录、1/3/7/14/30 天和 512 MB/1/2/5 GB。
- `AudioHistoryCleanupPlanner` 对年龄与总空间做同一次确定性规划，任一阈值触发即从最旧文件开始删除；`pending` 活动会话始终受保护。
- `SessionDiagnosticMetric` 独立于统计主表，只接受固定 Provider、路径、上下文来源和错误分类，以及非负数值；不包含正文、热词列表、上下文、Key、请求头或音频。
- `Redacted Diagnostics` 导出在保存前展示包含/排除清单，并对白名单字符串、非负有限数值再次收敛；最多导出最近 500 条，不包含系统原始日志。
- `scripts/evaluate_corpus.py` 强制至少 100 条语料及 50 条实体标注，拒绝同一实验结果重复写入，并要求每个实验组完整覆盖语料后才允许冻结参数；按实验路径汇总 CER、专业实体 Recall/Precision、误吸附率、最终修改率、P50/P95、成功率、CPU、RSS、Energy Impact 和网络字节。
- 评测工具不会调用 Provider、补齐样本或生成结果；私有 Manifest/录音/结果目录已忽略。详细格式与边界见 `docs/D_HISTORY_METRICS_EVALUATION.md`。
- finalized 句段增量写入和 AOQ 仍仅为独立实验，不进入默认主链路。VAD、超时、Top-K 和评分权重在个人真实完整数据到位前不冻结。
- 30 分钟真实空闲共 360 个样本：平均 CPU 0.0228%、最大 0.7%，平均 RSS 132.0 MiB、最大约 135.0 MiB，低于 150 MB 目标；采样末 footprint 46 MB、峰值 69 MB。RSS 与 footprint 口径不同，分别记录、不混算。峰值 414 MB 来自按需本地模型识别，不计作空闲模型常驻。
- 20 次独立重启的录音服务就绪 P50 为 0.101 秒、P95 为 0.106 秒、最大 0.109 秒；替代只测 PID 出现的粗略启动口径。

## 用户接受的后续验证

- 用户确认当前没有 100 条个人样本，并明确接受在其他工作完成后将本 Goal 标记完成。以下项目因此作为后续验证保留，而不是伪造结果或继续阻塞当前 Goal。
- 完整 100 条 A/B、SenseVoice/Whisper 对照和参数冻结仍需要个人录音、人工真值、至少 50 条实体标注及最终修改文本。
- HUD 首个可见非空文本和松键到 final tail 已能直接量测；当前只有 1 个首字样本和 4 个 tail 探索样本，仍不足以形成可信 P50/P95。首字单样本 1.008 s 高于 0.8 s 目标，不据此判定总体达标或失败。
- 连续 100 次个人短句和 30 分钟间歇使用内存增长仍未执行；纯空闲 30 分钟采样已完成。

## Goal 完成条件审计

| # | 当前结论 | 权威证据与缺口 |
|---|---|---|
| 1 | 已满足 | A～D 的产品功能均已实现；需要个人数据的参数冻结和模型对照按用户决定留作后续验证，不声称已有结论。 |
| 2 | 已满足 | 53 个 XCTest 与 4 个 Python 工具测试通过，真实百炼 Streaming/Batch 基础端到端和两级故障回退也已人工通过。 |
| 3 | 已满足 | 签名 Release 可构建、启动；SenseVoice、百炼 Streaming/Batch 以及 TextEdit、Chrome、VS Code 跨应用输入均已完成真人验收。 |
| 4 | 已满足 | Streaming、Batch 和 SenseVoice 真实路径均已通过；两级故障回退真实触发，焦点正确、每次只投递一个 final，对应会话临时 WAV 无残留。 |
| 5 | 已满足 | 动态热词、上下文隐私、录音历史、安全学习和脱敏指标均有实现、专项测试和可执行范围内的真实验收；个人语料效果 A/B 后续补测。 |
| 6 | 按当前范围已满足 | 空闲 CPU/RSS、启动、本地识别、Streaming 首个可见文本和 final tail 已实际测量；正式 P50/P95、连续 100 次与间歇使用增长因无个人样本由用户接受后续验证。 |
| 7 | 按当前范围已满足 | 100 条/50 条实体标注的工具和格式完整；用户未提供真实个人语料，并明确接受结束 Goal，因此没有生成或伪造 CER、实体指标、误吸附率和最终修改率。 |
| 8 | 已满足 | README、REQUIREMENTS、DEVELOPMENT、PROGRESS、UPSTREAM、D 阶段说明和最终报告已与实现及验证边界对齐。 |
| 9 | 已满足 | 最终审计确认工作区无意外文件、无 Git 远程、无凭据样式字面量；构建产物、模型、私有语料和结果均由忽略规则隔离。 |
| 10 | 已满足 | `docs/FINAL_REPORT.md` 列出实现、验证、实测指标、限制与全部本地提交。 |

基于用户对个人语料规模验证的明确延期决定，当前 Goal 标记完成。该结论只表示约定范围内的实现与现有验收收尾完成，不表示后续验证项目已经取得结果。

## 已解除阻塞

- 2026-09-19 已安装并选中 `/Applications/Xcode.app/Contents/Developer`；Xcode 首次启动组件和 `make check` 均通过。

## 后续需交互验证

- 后续代码变更使用同一 Apple Development 身份重建后，复核麦克风与 Accessibility 授权保持稳定。
- B2 的 TextEdit、Chrome、VS Code 真实跨应用 Streaming/final 投递、两级回退，以及首个可见非空文本/final tail 的直接时序量测均已完成；后续仍需个人语料规模的 P50/P95、连续 100 次与间歇使用稳定性验证。
- 首次 Parakeet 下载被隔离审计主动停止；共享 `~/Library/Application Support/FluidAudio` 中约 13 MB 的部分下载未自动删除，避免误删既有用户数据。
