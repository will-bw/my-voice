# my-voice

面向 macOS 的个人语音输入工具。

> 本项目是 [VoiceInk](https://github.com/Beingpax/VoiceInk) 的独立修改版本，由 [will-bw](https://github.com/will-bw) 维护，与 VoiceInk 官方无隶属或背书关系。源码按 GNU GPL v3 发布；上游归属、修改日期和变更摘要见 [NOTICE](NOTICE.md)。

项目以固定的 VoiceInk 源码快照为底座，接入阿里云百炼 Streaming/Batch ASR，并围绕动态热词、最小上下文、分级回退、安全纠错学习和隐私可控的历史记录进行定制。

## 文档

- [贡献与仓库公开范围](CONTRIBUTING.md)
- [上游来源与本地差异](UPSTREAM.md)
- [本地构建说明](BUILDING.md)

## 本地构建

```bash
git clone https://github.com/will-bw/my-voice.git
cd my-voice
```

需要完整 Xcode，而不只是 Command Line Tools：

```bash
make check
make local
open dist/my-voice.app
```

本地构建使用独立的应用标识、Keychain 和 Application Support 目录；不会连接 VoiceInk 官方更新源，也不会调用其商业 License 服务。

## 使用与隐私

- 在“音频设置”中开启“同时录制系统声音”，并授予 macOS“屏幕与系统音频录制”权限，可同时采集所选麦克风和其他应用的播放声音，适用于戴耳机开会。开启后会跳过自动静音和暂停媒体；关闭后恢复麦克风录音。设置在下次录音生效。
- 系统声音模式会把其他应用的声音一并混入录音和转写；使用云端识别时，这部分音频同样会发送给所选服务。该采集路径不保存屏幕画面，也不自动区分发言人。
- 百炼及其他云端服务需要自行配置 API Key；云端识别会向所选服务发送音频，润色和 AI 纠错会按功能配置发送文本或上下文。
- API Key 保存在本机 Keychain。个人热词、录音、诊断结果、模型及构建产物不包含在公开仓库内。
- 目前提供源码和本地构建方法，尚未提供经过签名公证的安装包。
- 本修改版的问题请提交到 [本仓库 Issues](https://github.com/will-bw/my-voice/issues)。

## 许可与归属

本项目作为 VoiceInk 的修改版本，整体按 **GNU General Public License version 3（GPL-3.0）** 发布，许可全文见 [LICENSE](LICENSE)。你可以依照该许可证使用、修改和再分发；本项目不提供任何担保。

保留上游作者及贡献者的权利和现有声明。固定来源见 [UPSTREAM.md](UPSTREAM.md)，修改声明见 [NOTICE.md](NOTICE.md)；导入时上游提供的许可证节选原样保存在 [licenses/VoiceInk-original-LICENSE.txt](licenses/VoiceInk-original-LICENSE.txt)。第三方依赖及模型继续适用各自的许可证，VoiceInk 名称与标识的保留用于来源识别，不表示官方发布或背书。
