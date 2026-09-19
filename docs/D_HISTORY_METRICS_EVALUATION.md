# D 历史、脱敏指标与评测

更新日期：2026-09-19

## 原始录音历史

原始录音默认不保存。录音文件只为当前 Streaming/Batch/本地回退会话存在于应用专属临时目录；完成、失败或取消后删除，并把转写记录中的音频地址清空。若应用崩溃，下一次启动会清除该临时目录中的遗留会话文件。

用户可在 History Settings 显式开启 `Save Recording History`，选择保存目录、保留天数和空间上限。初始限制为 7 天和 1 GB；任何一个条件达到时按时间从旧到新删除。仍处于 `pending` 的活动会话受保护。“Clear All Recording History”只删除非活动原始音频，保留文本历史、词库和纠错反馈。

## 脱敏会话指标

`SessionDiagnosticMetric` 只接受固定枚举和数值：

- 成功状态、实际 Provider、回退路径；
- 音频时长、转写耗时、增强耗时和总耗时；
- 热词数量及上下文来源类型；
- 固定错误分类。

Provider、路径、上下文类型和错误分类在写入前经过白名单收敛。该表没有 API Key、请求头、转写正文、原始错误正文、上下文正文、热词明文或音频字段。

设置页的 `Redacted Diagnostics` 只导出上述白名单会话字段，以及应用/构建版本、macOS、CPU 架构和录音历史是否开启。导出按钮会先展示明确的包含/排除清单；确认后才选择保存位置。导出过程会再次收敛 SwiftData 中的字符串和数值，因此即使本地记录被异常修改，也不会把原始 Provider、路径、上下文、错误文本、非有限耗时或原始系统日志写入诊断包。最多导出最近 500 条会话。

## 私有语料格式

个人语料和运行结果放入已忽略的 `evaluation/private/` 与 `evaluation/results/`，不得提交。Manifest 使用 UTF-8 JSONL，每行一条：

```json
{"id":"唯一编号","audio_path":"绝对或相对音频路径","reference_text":"人工校对真值","entities":[{"text":"专业实体","type":"project"}]}
```

正式 Manifest 至少 100 条，其中至少 50 条的 `entities` 非空。命令行运行会逐条确认相对 Manifest 目录或绝对路径指向真实音频文件；工具会拒绝规模不足、缺失音频、重复 ID、空真值或错误实体结构，不会补造样本。

每个实验结果也是 JSONL：

```json
{"id":"对应编号","arm":"dynamic","provider":"SenseVoice Small","success":true,"hypothesis":"模型原始结果","final_text":"用户最终修改结果","predicted_entities":["模型命中的实体"],"latency_ms":180,"cpu_seconds":0.4,"peak_rss_mb":92,"energy_impact":3.1,"network_bytes":0,"hotword_count":12,"false_hotword_attractions":0}
```

失败项仍需保留 `id`、`arm`、`provider`、`success=false` 和 `latency_ms`。`final_text`、资源字段和实体预测可在尚未采集时省略，报告会明确输出 `null`，不会推断或伪造。

运行：

```sh
python scripts/evaluate_corpus.py \
  --manifest evaluation/private/manifest.jsonl \
  --results evaluation/results/runs.jsonl
```

输出按 `arm + provider` 汇总 CER、实体 Recall/Precision、热词误吸附率、最终修改率、成功率、P50/P95 延迟，以及 CPU、峰值 RSS、Energy Impact 和网络字节。工具拒绝重复的 `id + arm + provider`、空成功结果及无效数值字段；只有同一 Provider 下的 `none`、`all`、`dynamic` 三条可比实验臂都存在，并且每个实验组都恰好覆盖 Manifest 的全部 ID 时，`parameter_freeze_allowed` 才为 `true`。VAD、超时、Top-K 和评分权重只能在真实完整数据上冻结。

## 实验边界

finalized 句段增量写入和 AOQ 保持独立实验，不进入默认录音主线。当前没有个人 100 条录音和百炼凭证，因此本检查点只交付实现、Mock/单元测试、格式验证和测量框架，不写入任何声称真实的准确率或云端结果。

## 当前本机性能证据

- 20 次独立冷启动的录音服务就绪时间：平均 0.099 秒、P50 0.101 秒、P95 0.106 秒、最大 0.109 秒；由服务初始化完成后的生命周期日志测量，不再以 PID 出现冒充就绪。
- 30 分钟真实空闲、每 5 秒一次共 360 个样本：平均 CPU 0.0228%、最大 0.7%；平均 RSS 132.0 MiB、最大约 135.0 MiB。采样末 `footprint` 为 46 MB、峰值 69 MB；RSS 与 footprint 是不同口径，保留两者原始含义。
- 预置崩溃遗留临时 WAV 后启动签名 Release，应用初始化时已成功删除该文件。

这些数据只证明当前 Mac 上的空闲与启动基线。连续 100 次个人短句、30 分钟间歇使用内存增长、云端 Streaming 首 partial/final 尾延迟和准确率仍待真实个人语料与凭证。
