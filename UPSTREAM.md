# 上游来源与本地差异

## 固定来源

- 项目：VoiceInk
- 仓库：https://github.com/Beingpax/VoiceInk
- 固定提交：`cd1d96f182b03561f5ef66c6a91e511cd7409c4c`
- 上游提交时间：2026-09-17T14:34:47+05:45
- 导入日期：2026-09-19
- 导入方式：在临时目录检出固定提交，再通过 `git archive` 将 465 个跟踪文件展开到当前仓库；未携带上游 `.git`。
- 校验：导入后逐文件执行 `git hash-object`，465 个 blob 与上游树全部一致。
- 许可证：GPL-3.0；保留根目录 `LICENSE`。
- `LICENSE` SHA-256：`ffc4047c35e2601b4eb76e810b06d5d9754104e8f0e9b057c8a885fb8c7d4776`

纯上游快照对应本地提交 `d99c4dd`。需求与开发设计基线在其前一提交 `b235afd`，不会混入上游历史。

## 构建方式

目标环境为 macOS 14.4 及以上和完整 Xcode。当前本地入口：

```bash
make check
make local
open dist/my-voice.app
```

`make local` 使用 `LocalBuild.xcconfig`、`VoiceInk.local.entitlements` 和 `LOCAL_BUILD`/`MYVOICE_LOCAL_BUILD` 编译条件。构建产物、Derived Data 和外部模型/依赖不得提交。

## 当前本地差异

检查点 A 在纯快照之后引入以下隔离改动：

1. 本地构建产物输出为 `dist/my-voice.app`，避免覆盖官方 `VoiceInk.app`。
2. 本地构建使用 `com.will.myvoice.*` Bundle ID、`com.will.myvoice` Keychain service 和 `com.will.myvoice` Application Support 目录，不读取或覆盖官方应用数据。
3. 删除官方 Sparkle feed 与签名元数据；`LOCAL_BUILD` 下更新检查入口为无操作，不能安装官方发布包。
4. `LOCAL_BUILD` 下商业 License 状态固定为本地可用，购买、验证和停用网络入口均被禁用，不调用 Polar 服务。
5. 保留本项目 `docs/`，并新增本文件与 `docs/PROGRESS.md`。

## 尚未完成的基线验证

当前机器的 `xcode-select` 指向 `/Library/Developer/CommandLineTools`，且未发现完整 Xcode，因此尚未完成依赖解析、编译、启动和权限/输入链路实测。未通过这些验证前，检查点 A 不视为完成，也不得进入 B1。
