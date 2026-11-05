# 许可、归属与修改声明

**my-voice 是 VoiceInk 的独立修改版本，整体按 GNU GPL version 3 发布。**

## 上游归属

- 原项目：[VoiceInk](https://github.com/Beingpax/VoiceInk)，由 Beingpax 和 VoiceInk 贡献者开发；原有作者、版权与许可声明继续保留。
- 基于固定提交 [`cd1d96f182b03561f5ef66c6a91e511cd7409c4c`](https://github.com/Beingpax/VoiceInk/tree/cd1d96f182b03561f5ef66c6a91e511cd7409c4c)，于 2026-09-19 导入。
- 上游原始许可证节选见 [licenses/VoiceInk-original-LICENSE.txt](licenses/VoiceInk-original-LICENSE.txt)。本仓库随附 [GPLv3 完整文本](LICENSE)，取自 [GNU 官方](https://www.gnu.org/licenses/gpl-3.0.txt)。
- 本项目由 [will-bw](https://github.com/will-bw) 独立维护；不代表 VoiceInk 官方，也不暗示官方认可或背书。

## 修改说明与日期

以下日期对应本修改版的开发记录；具体文件差异可将当前版本与本地导入提交 `d99c4dd` 比较。

| 日期 | 修改摘要 |
| --- | --- |
| 2026-09-19 | 隔离应用标识、Keychain、数据和模型目录；关闭本地构建中的官方更新与商业许可联网路径；固定 whisper.cpp 依赖。 |
| 2026-09-19 | 增加百炼 Streaming/Batch、SenseVoice Small 回退、动态热词、安全纠错学习、隐私历史、诊断与评测工具，调整首次引导。 |
| 2026-09-19 至 2026-10-22 | 调整自定义百炼 Qwen 润色请求的思考参数，并保留对应测试；具体原始编辑日期未单独记载，纳入本次公开源码版本。 |
| 2026-10-06 | 修复百炼错误分类、健康状态冷却恢复、流式启动期限、取消与缓冲队列处理，补充回归测试。 |
| 2026-10-22 | 准备公开源码：补齐 GPLv3 全文、归属及修改声明、更新项目说明并排除个人热词和凭据文件。 |
| 2026-10-26 | 增加可选的系统声音与麦克风同步混音、权限入口、实时转写接入和音频测试。 |
| 2026-10-26 | 修复双路录音的权限前置判断，统一采用 ScreenCaptureKit 实际查询结果并增加权限回归测试。 |

本仓库包括对应源码、构建配置和脚本，可按 [BUILDING.md](BUILDING.md) 本地构建。本次不分发二进制安装包。

## 第三方组件

Swift Package Manager 依赖的来源和固定 revision 记录在 `VoiceInk.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved`，whisper.cpp 的来源和固定 revision 记录在 `Makefile`。依赖源码及模型权重未随本仓库重新打包，其各自的许可、版权和通知仍然适用；如另行分发含这些组件的二进制，应一并保留所需许可和通知，并满足对应源码提供义务。

VoiceInk 代码、资源中的现有归属和通知予以保留。代码许可证不表示获得上游商标背书。本软件按 GPLv3 的条款不提供担保，详见 LICENSE 第 15–17 节。
