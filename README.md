# my-voice

面向 macOS 的个人语音输入工具。项目以固定的 VoiceInk 源码快照为底座，计划接入阿里云百炼 Streaming/Batch ASR，并围绕动态热词、最小上下文、分级回退和安全纠错学习进行定制。

当前处于检查点 A（上游基线）：VoiceInk `cd1d96f182b03561f5ef66c6a91e511cd7409c4c` 已导入；百炼 Provider 尚未开始实现。实际进度和验证边界以 [docs/PROGRESS.md](docs/PROGRESS.md) 为准。

## 文档

- [产品需求 v0.2](docs/REQUIREMENTS.md)
- [开发设计 v0.1](docs/DEVELOPMENT.md)
- [开发进度](docs/PROGRESS.md)
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
