# my-voice

面向 macOS 的轻量语音输入工具。项目拟以 VoiceInk 原生 Swift 架构为底座，接入阿里云百炼 ASR，并围绕动态热词、最小化上下文和安全纠错学习进行定制。

当前需求基线已经确认，尚未导入 VoiceInk 源码。默认方案为百炼 Streaming，百炼 Batch 与 SenseVoice Small 组成分级回退链路。

- [需求文档](docs/REQUIREMENTS.md)
- [开发设计文档](docs/DEVELOPMENT.md)
