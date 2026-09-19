# 百炼 ASR 协议复核（2026-09-19）

本文记录检查点 B1 实现当天对阿里云官方文档的复核结果。它是实现证据快照，不替代官方文档；后续协议变更时必须重新核对。

## 模型与调用方式

- Streaming：`qwen-audio-3.0-asr-flash-streaming`，WebSocket，单声道二进制音频流。
- Batch：`qwen-audio-3.0-asr-flash`，同步 HTTP，适用于不超过 5 分钟的短音频，输入支持 URL 或 Base64。
- Batch 固定使用 `POST /api/v1/services/aigc/multimodal-generation/generation`，并设置 `X-DashScope-SSE: disable`。
- 鉴权均使用 `Authorization: Bearer <API Key>`。

## 地域与端点

官方已推荐业务空间专属域名，因此配置必须同时包含地域与 Workspace ID：

- 北京 HTTP：`https://{WorkspaceId}.cn-beijing.maas.aliyuncs.com/api/v1/services/aigc/multimodal-generation/generation`
- 北京 WebSocket：`wss://{WorkspaceId}.cn-beijing.maas.aliyuncs.com/api-ws/v1/inference`
- 新加坡域名后缀：`{WorkspaceId}.ap-southeast-1.maas.aliyuncs.com`

API Key、Workspace ID、HTTP 端点与 WebSocket 端点必须属于同一地域；客户端不自动跨地域尝试。

## Streaming 事件

1. 建立 WebSocket，握手请求头携带 Bearer API Key。
2. 发送 `run-task`，其中 `streaming` 为 `duplex`，任务组为 `audio`，任务为 `asr`，功能为 `recognition`。
3. 收到 `task-started` 后才允许发送二进制音频。
4. `result-generated` 通过 `sentence_id` 标识句段；`sentence_end=false` 为中间结果，`true` 为确认句段。
5. 音频发送完成后发送 `finish-task`；只有 `task-finished` 才代表完整结束。
6. `task-failed` 后连接不可复用。

设置页的“验证连接”使用同一条 Streaming 握手与 `run-task` 协议，并以收到 `task-started` 作为成功条件；确认后立即关闭会话，不发送音频。这样可以验证 API Key、Workspace、地域、端点和默认 Streaming 模型，同时避免用静音或合成音频冒充真实转写，也避免服务端以“静音/音频过短”拒绝 Batch 探针。

实现按 `sentence_id` 去重和排序，不使用模糊字符串包含判断。`task-finished` 没有有效文本时归类为空 final，而不是成功。

## 热词、语言与上下文

- 即时热词在 `parameters.vocabulary` 中以内联键值对传递。
- 权重只能为 1～5 或 50；权重 50 的超级热词最多 50 个。
- Qwen-Audio 3.0 系列即时热词最多 2,000 个；本项目仍只选择 Top 30～80。
- `language_hints` 最多 4 个值。
- Streaming 上下文在 `run-task.payload.input.context` 中传递。
- Batch 上下文作为 `input.messages` 中位于音频消息之前的文本消息传递。
- 每轮上下文总长度不超过 400 字符；用户与助手消息各最多 5 条。

## 官方依据

- [语音识别模型与音频规格](https://help.aliyun.com/zh/model-studio/asr-model/)
- [实时语音识别用户指南](https://help.aliyun.com/zh/model-studio/real-time-speech-recognition-user-guide)
- [非实时语音识别用户指南](https://help.aliyun.com/zh/model-studio/non-realtime-speech-recognition-user-guide)
- [WebSocket API 地址、请求头与交互](https://help.aliyun.com/zh/model-studio/fun-asr-realtime-websocket-api)
- [客户端事件](https://help.aliyun.com/zh/model-studio/fun-asr-client-events)
- [服务端事件](https://help.aliyun.com/zh/model-studio/fun-asr-server-events)
- [热词与上下文增强](https://help.aliyun.com/zh/model-studio/improve-asr-accuracy)
