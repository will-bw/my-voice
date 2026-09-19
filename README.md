# my-voice

面向 macOS 的个人语音输入工具。项目以固定的 VoiceInk 源码快照为底座，接入阿里云百炼 Streaming/Batch ASR，并围绕动态热词、最小上下文、分级回退、安全纠错学习和隐私可控的历史记录进行定制。

检查点 A、B1、B2、B3、C、D 的非凭证实现已经完成，首次引导默认配置 Bailian Streaming，并提供 SenseVoice Small 离线兜底。真实百炼 Streaming/Batch、100 条个人语料 A/B 和跨浏览器/代码编辑器验收仍需要用户 API Key 与个人录音；实际进度和验证边界以 [docs/PROGRESS.md](docs/PROGRESS.md) 为准。

## 文档

- [产品需求 v0.2](docs/REQUIREMENTS.md)
- [开发设计 v0.1](docs/DEVELOPMENT.md)
- [开发进度](docs/PROGRESS.md)
- [安全纠错学习](docs/C_SAFE_LEARNING.md)
- [历史、脱敏指标与评测](docs/D_HISTORY_METRICS_EVALUATION.md)
- [上游来源与本地差异](UPSTREAM.md)
- [本地构建说明](BUILDING.md)

## 本地构建

需要完整 Xcode，而不只是 Command Line Tools：

```bash
make check
make local
open dist/my-voice.app
```

本地构建使用独立的应用标识、Keychain 和 Application Support 目录；不会连接 VoiceInk 官方更新源，也不会调用其商业 License 服务。

## 许可

上游 VoiceInk 采用 GPL-3.0。本仓库保留上游 [LICENSE](LICENSE)，来源与固定提交见 [UPSTREAM.md](UPSTREAM.md)。当前项目仅供个人使用，不包含公开发布、签名公证或商业发行流程。
