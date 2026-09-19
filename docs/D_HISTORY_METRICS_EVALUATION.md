# D 历史、脱敏指标与评测

更新日期：2026-09-19

## 原始录音历史

原始录音默认不保存。录音文件只为当前 Streaming/Batch/本地回退会话临时存在；完成、失败或取消后删除，并把转写记录中的音频地址清空。

用户可在 History Settings 显式开启 `Save Recording History`，选择保存目录、保留天数和空间上限。初始限制为 7 天和 1 GB；任何一个条件达到时按时间从旧到新删除。仍处于 `pending` 的活动会话受保护。“Clear All Recording History”只删除非活动原始音频，保留文本历史、词库和纠错反馈。

## 脱敏会话指标

`SessionDiagnosticMetric` 只接受固定枚举和数值：

- 成功状态、实际 Provider、回退路径；
- 音频时长、转写耗时、增强耗时和总耗时；
- 热词数量及上下文来源类型；
- 固定错误分类。

Provider、路径、上下文类型和错误分类在写入前经过白名单收敛。该表没有 API Key、请求头、转写正文、原始错误正文、上下文正文、热词明文或音频字段。

## 私有语料格式

个人语料和运行结果放入已忽略的 `evaluation/private/` 与 `evaluation/results/`，不得提交。Manifest 使用 UTF-8 JSONL，每行一条：

```json
{"id":"唯一编号","audio_path":"绝对或相对音频路径","reference_text":"人工校对真值","entities":[{"text":"专业实体","type":"project"}]}
```

正式 Manifest 至少 100 条，其中至少 50 条的 `entities` 非空。工具会拒绝规模不足、重复 ID、空真值或错误实体结构，不会补造样本。

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

输出按 `arm + provider` 汇总 CER、实体 Recall/Precision、热词误吸附率、最终修改率、成功率、P50/P95 延迟，以及 CPU、峰值 RSS、Energy Impact 和网络字节。工具拒绝重复的 `id + arm + provider` 结果；只有每个实验组都恰好覆盖 Manifest 的全部 ID 时，`parameter_freeze_allowed` 才为 `true`。VAD、超时、Top-K 和评分权重只能在真实完整数据上冻结。

## 实验边界

finalized 句段增量写入和 AOQ 保持独立实验，不进入默认录音主线。当前没有个人 100 条录音和百炼凭证，因此本检查点只交付实现、Mock/单元测试、格式验证和测量框架，不写入任何声称真实的准确率或云端结果。
