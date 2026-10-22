# 百炼无语音响应导致持续本地兜底的修复

日期：2026-10-06

## 故障与根因

用户提供的两次日志均显示：Streaming 空结果触发 Batch 回退；Batch 返回 HTTP 400，业务错误为 `ASR_RESPONSE_HAVE_NO_WORDS`；错误被归为 `.misconfigured` 并写入 Streaming/Batch 共用的内存健康状态。之后 `ensureAttemptAllowed()` 在请求发出前拒绝调用，直到重启或保存凭据/配置才恢复。

源码核对确认 `map(statusCode:responseBody:)` 原先忽略响应体，所有普通 4xx 都进入配置错误分支。单次 `.protocolViolation`、`.invalidResponse` 也被归为永久配置错误；WebSocket 发送/接收错误会使用握手留下的 HTTP 101，将底层断线或超时误判为响应异常。

原有 `fail()` 已有终态保护，因此失败后的迟到音频不会重复写健康状态，但会返回新的协议错误。发送循环原先只记录错误而继续发送，增加重复调用并掩盖原始原因。

## 第一轮修复行为（09:59 安装，未完整解决）

- HTTP 400 的结构化 `code`/`message` 含 `ASR_RESPONSE_HAVE_NO_WORDS` 时归为 `.emptyFinal`；WebSocket `task-failed` 使用相同规则。不把响应体或服务端原始消息加入日志。
- `.protocolViolation`、`.invalidResponse` 归为可重试的单次失败；真实 `.misconfigured`、401/403 凭据错误继续拦截后续请求。
- WebSocket HTTP 101 保留底层网络、超时或取消错误；真实握手失败仍按 HTTP 状态分类。
- 会话保留第一个终态错误，迟到音频和结束请求返回原始原因；结束中、已结束、已取消的会话拒绝音频而不污染全局健康状态。
- 发送失败或观察到 provider 错误后停止网络发送，关闭音频队列并将剩余音频计为丢弃，保留完整录音回退机制。

第一轮保留现有 Streaming → Batch → SenseVoice Small 回退路径，但错误码特判只覆盖含 `code/message` 的响应。16:10 的复发证明不能将上述 Mock 测试通过视为真实接口的完整验收。

## 验证范围

回归测试覆盖同一健康状态下的「Streaming 空结果 → Batch 无语音 400 → 下一次 Streaming 成功」、无语音 Batch 后下一次 Batch 成功、协议/断线恢复、HTTP 101 错误映射、凭据与配置错误继续拦截，以及发送失败后不再调用 provider 发送排队音频。

完整 `VoiceInkTests` 共 64 个 XCTest 全部通过，其中新增 8 个回归测试；Release 应用与测试模块编译通过，`git diff --check` 通过。测试结果：`.local-build/Logs/Test/Test-VoiceInk-2026.10.06_09-55-07-+0800.xcresult`。

可复现命令（Release 测试需显式开启 `ENABLE_TESTABILITY`）：

```sh
xcodebuild -project VoiceInk.xcodeproj -scheme VoiceInk -configuration Release \
  -derivedDataPath .local-build -destination 'platform=macOS' \
  -xcconfig LocalBuild.xcconfig ENABLE_TESTABILITY=YES \
  CODE_SIGN_IDENTITY='' CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO DEVELOPMENT_TEAM='' \
  -skipPackagePluginValidation -skipMacroValidation -only-testing:VoiceInkTests test
```

第一轮以用户提供的历史网络实测作为故障输入，未使用真实 API Key 或进行麦克风端到端实测。修复保留为工作区改动，已有润色功能及文档改动未被覆盖。

## 安装验证

用户随后授权替换现有应用，已于 2026-10-06 09:59（Asia/Hong_Kong）完成：

- 使用当前工作区构建签名 Release 版本，包含本次修复及此前已有的润色配置改动；构建与本地隔离检查通过。
- 新旧 Bundle ID 均为 `com.will.myvoice.VoiceInk`，Apple Development 签名身份、TeamIdentifier `22ABMXL88T` 和 designated requirement 一致。
- 替换 `/Applications/my-voice.app` 并重启；运行进程 PID `14253` 的可执行路径为 `/Applications/my-voice.app/Contents/MacOS/VoiceInk`，启动后仍存活。
- 安装后 `codesign --verify --deep --strict` 通过，二进制 SHA-256 为 `82290fdc79d358d6a9523323b330fd16a27ae27d9e8d12a7699871c2dfd52e82`。
- 旧版备份：`~/Library/Application Support/my-voice-backups/my-voice-before-bailian-fix-20261006-095655.zip`，ZIP 完整性检查通过；原应用移至 `~/.Trash/my-voice-before-bailian-fix-20261006-095936.app`。

安装验收覆盖构建、身份、签名、替换和启动；真实录音及持续使用后的恢复表现仍需实际使用验证。

## 16:10 复发与第二轮修复

2026-10-06 16:10:01（Asia/Hong_Kong），PID `14253` 的第一轮修复版再次出现流式空结果 → Batch `misconfigured("HTTP 400")` → 后续请求被健康状态拒绝。运行二进制 SHA-256 与第一轮安装记录一致，排除运行旧版的可能。

直接调用当前配置的 Batch 接口，无语音正弦波音频返回 HTTP 400，响应体为 `{}`。随后三轮真实静音请求均返回相同的两字节 `{}`。第一轮测试使用了人为构造的顶层 `code/message`，未覆盖真实网关隐藏错误字段的情况，这是上一轮修复不完整的原因。

第二轮采取以下规则：

- 保留已知 `ASR_RESPONSE_HAVE_NO_WORDS` → `.emptyFinal` 的映射。其他普通 4xx（除 401/403/429）以及流式 `CLIENT_ERROR` 归为 `.requestRejected`，只影响当前请求，健康状态允许下一次录音重试。不能只凭 HTTP 400 推断持久配置错误。
- `.invalidCredential`、`.misconfigured` 使用单调时钟进行 30 秒冷却，期限到达后允许再次尝试。被本地拦截的调用不会延长冷却期限；Batch 将健康状态检查移出远程请求的 catch，避免将本地拦截重复记作服务端失败。
- 新错误类型同步映射到云端服务、流式服务及脱敏诊断类别，日志不包含原始响应、API Key 或音频。
- 新增真实 `{}`、空响应、非 JSON 响应、嵌套错误响应的回归输入；验证未知 400 后下一次 Batch/Streaming 成功，以及冷却自动恢复和频繁调用不延长冷却。

### 真实网络验证

使用修复后的 `BailianStreamingSession`、`BailianBatchClient`、`BailianErrorMapper`、`BailianProviderHealthStore` 源文件编译独立验证程序；通过本机 Keychain 在内存中读取现有 Key，测试期间没有改动凭据或配置。

以 1 秒静音和本地 Tingting 合成的非私人中文音频连续执行三轮：

1. Streaming 静音返回 `.emptyFinal`。
2. Batch 同一静音返回 HTTP 400、响应体 `{}`，映射为 `.requestRejected(statusCode: 400)`。
3. 同一个健康状态对象立即建立新的 Streaming 连接，返回完整文本「百炼语音转写恢复测试，静音之后仍然可以继续使用云端。」。

三轮全部通过，健康状态 reset 次数为 0，无进程重启。验证输出在 `/tmp/my-voice-live-recovery.log`。这是 provider 层的真实网络恢复验证，尚不等同于通过 App 麦克风、快捷键和目标输入框的完整端到端验收。

### 第二轮自动化结果

完整 `VoiceInkTests` 共 68 个 XCTest 全部通过，`git diff --check`、`make verify-local-isolation` 通过。结果：`.local-build/Logs/Test/Test-VoiceInk-2026.10.06_16-18-48-+0800.xcresult`。

其中第一轮遗留的空结果测试曾因只依赖 `Task.yield()` 而模拟出 `task-finished` 早于 `finish-task` 的竞态；已改为等待 Mock transport 实际发出 `finish-task`，相关用例使用确定的协议顺序再重跑全量测试。

### 第二轮安装验证

2026-10-06 16:22（Asia/Hong_Kong）已替换并重启 `/Applications/my-voice.app`：

- 签名 Release 构建成功，新旧 Bundle ID、Apple Development 签名身份及 designated requirement 一致，安装后 deep/strict 签名检查通过。
- 新进程 PID `38622` 于 16:22:03 启动；`ps` 和 `lsof` 确认其加载的可执行文件为 `/Applications/my-voice.app/Contents/MacOS/VoiceInk`。
- 第二轮二进制 SHA-256：`6e5349eaf0b511ad267a8202c1adc8fe0b5ca96151fdb0f0cec7f5ed2bb25b32`，与签名构建产物一致。
- 第一轮版本备份：`~/Library/Application Support/my-voice-backups/my-voice-before-recovery-v2-20261006-161919.zip`，完整性检查通过；原 App 移至 `~/.Trash/my-voice-before-recovery-v2-20261006-162209.app`。

第二轮完成了真实 provider 恢复验证及安装启动验证；用户通过 App 麦克风进行长时间实际听写的结果仍应单独记录，不用自动化或合成语音的通过情况替代。

## 18:51 转圈无文字与第三轮修复

用户反馈一直转圈，最终没有文字。运行进程仍为第二轮安装的 PID `38622`。这次日志中没有持续配置熔断，存在以下已观察到的问题：

- 18:44:57 与 18:51:46 的流式连接均成功，但录音收到 289/310 块音频，最终 `sentChunks=0`。录音在模式与提示准备期间已经开始；准备结束后向只有 64 KB 的流式队列集中释放了超过两秒的音频。此前修复把队列溢出也当成 provider 终止错误，发送循环丢弃了所有仍可发送的音频。这是本次修复引入的回归。
- 18:51:09 出现 TLS 网络错误 `-1200`。Batch 回退分别耗时约 30.5 秒与 9.7 秒，最终有识别文字，但处理期间发生取消，未完成文字投递。日志不能证明取消由哪种 UI 操作触发。
- 原来 `task-started` 的超时从 `connect()` 返回之后才开始；WebSocket 在 `run-task` 的底层发送中挂起时，没有覆盖整段启动过程的期限。单纯取消 Swift task 也不能保证释放挂起的 WebSocket 操作。

受控比较系统代理与禁用 URLSession 代理的路径，两种路径都出现延迟或超时。系统代理为本机 Clash Verge，且 TUN 开启，禁用 URLSession 代理并不等于绕过所有路由。因此未修改系统代理、节点、API Key、模式配置或证书校验。

第三轮修复：

- 将“不完整录音”和“provider 已终止”分成独立状态：队列溢出仍要求完整文件回退，但继续发送已接受的音频；真实发送错误或 provider 错误停止发送。即使先溢出、后断线，也只向失败 provider 发送一次。
- 流式服务在启动阶段提供最多 20 秒（640 KB）的 PCM16 缓冲。连接成功后保留已有积压，队列排空至正常预算后恢复两秒（64 KB）限制，不扩大正常录音阶段的背压预算。
- 百炼新增覆盖握手、`run-task` 与 `task-started` 的 15 秒启动期限。超时先关闭 transport，释放底层挂起操作；取消也关闭 transport。启动状态信号独立于转写输出，避免两个消费者争抢事件。
- 音频发送与 `finish-task` 各有 15 秒期限，超时关闭 transport 并保留 `.timeout` 原因，允许下一次录音重新连接。

真实 provider 验证再次完成「静音 Streaming → Batch 400 `{}` → 同一健康状态下 Streaming 识别完整测试句」，没有重启或 reset。输出：`/tmp/my-voice-startup-live-probe.log`。

### 第三轮自动化与安装结果

完整 `VoiceInkTests` 共 78 个 XCTest 全部通过，无跳过；`git diff --check` 与 `make verify-local-isolation` 通过。结果：`.local-build/Logs/Test/Test-VoiceInk-2026.10.06_19-09-16-+0800.xcresult`。新增用例覆盖超过两秒的启动音频完整发送、启动预算回收、背压后继续发送与断线后停止、挂起的启动/音频/结束发送超时、启动取消以及启动信号不抢占转写输出。

取消用例曾暴露 deadline timer 可能直接抛出 Swift `CancellationError`，已统一通过 `BailianErrorMapper` 返回百炼取消错误后重跑全量；未通过的中间构建没有安装。

2026-10-06 19:14（Asia/Hong_Kong）完成签名 Release 构建、备份、替换与重启：

- 新进程 PID `52235` 于 19:14:26 启动，加载 `/Applications/my-voice.app/Contents/MacOS/VoiceInk`；旧 PID `38622` 已退出。
- 二进制 SHA-256：`8aabaf6f926629686db5a5fd0fb67285a14501f10f8453385568f12e02d23f4c`，与构建产物一致。
- Bundle ID、TeamIdentifier、designated requirement 与旧 App 一致；安装后 deep/strict 签名验证通过。
- 旧版备份：`~/Library/Application Support/my-voice-backups/my-voice-before-startup-fix-20261006-191423.zip`，ZIP 完整性检查通过；原 App 移至 `~/.Trash/my-voice-before-startup-fix-20261006-191423.app`。

### 新版 App 真实文件转写验收

通过新版 App 的「转写」页面、现有 Dictation 模式操作，不修改 API Key 或模式配置，同一个 PID `52235` 连续执行：

1. 合成测试句 WAV 转写成功，界面显示「百炼语音转写恢复测试静音之后，仍然可以继续使用云端。」。
2. 一秒静音 WAV 在界面提示本次 HTTP 400 请求失败；没有持续转圈。
3. 再次导入同一测试句 WAV，云端正常返回文字；期间没有重启进程、保存配置或 reset 健康状态。

unified log（`com.will.myvoice:BailianProvider`）确认 19:18:43 HTTP 200 → 19:19:28 `.requestRejected(statusCode: 400)` → 19:20:12 HTTP 200，均来自 PID `52235`。日志：`/tmp/my-voice-native-cloud-results.log`。

原生验收覆盖 App 文件输入、实际百炼 Batch 请求、错误恢复及界面显示。自动化发送现有全局快捷键未触发录音，没有得到麦克风到目标输入框的验收证据；不将文件转写或 provider 层流式测试说成快捷键麦克风链路已通过。长期连续听写效果仍需实际使用记录。
