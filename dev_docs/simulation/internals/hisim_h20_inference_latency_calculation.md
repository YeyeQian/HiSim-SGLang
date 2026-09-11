# HiSim 如何计算 H20 推理延迟

## 1. 结论概览

当前 H20 路径并不是在本服务器上执行 Qwen3-8B 的真实 GPU forward。SGLang 仍负责形成实际请求 batch，HiSim hook 把每个请求压缩成“本轮输入 Token 数、已有 KV Token 数”，再由 AIConfigurator 根据 Qwen3-8B 结构、H20 性能表和解析带宽模型估算各项算子耗时。各项毫秒值求和、应用 Prefill/Decode 修正系数后转换成秒，交给 HiSim 的模拟时钟。

当前固定配置是 Qwen3-8B、SGLang `0.5.6.post2`、H20 数据路径、FP16 权重/激活、FP16 KV cache、`tp_size=1`。Prefill 总时延乘 `1.045`，Decode 总时延乘 `1.0`；Decode attention 还可按 batch size 选择 XGBoost 模型进行校正。配置见 [`configs/h20-qwen3-8b.json`](../configs/h20-qwen3-8b.json)。

这些结果目前只证明固定 H20 predictor 数据能够驱动 HiSim + SGLang 全链路，属于集成验证；本项目没有在本机实体 H20 上独立采样并校准，因此不能把模拟值表述为本服务器真卡性能。

## 2. 整体调用链

```text
SGLang Scheduler 形成 ScheduleBatch
  ↓
HiSim wrapped_run_batch 读取 forward_mode 和每个请求状态
  ↓
构造 FakeRequest(input_length, past_kv_length)
  ↓
ScheduleBatch.is_decode() 判定整个 batch 是 Decode 还是 Prefill
  ↓
AIConfiguratorTimePredictor.predict_infer_time()
  ↓
构造 RuntimeConfig(batch_size, isl, prefix, osl, correction scale)
  ↓
AIConfigurator InferenceSession.run_static()
  ↓
逐项查询 Qwen3-8B Operator latency
  ↓
求和、应用 1.045/1.0、ms → s
  ↓
HiSim 保存本轮 inference duration
  ↓
process_batch_result 合并 HiCache 时延、推进全局时钟并生成请求级 TTFT/TPOT/ITL
```

SGLang hook 位于 [`sglang_hook.py`](../third_party/tair-kvcache/hisim/src/hisim/simulation/sglang/sglang_hook.py)。它只在 SGLang 返回 `GenerationBatchResult` 后建立 HiSim batch：

- 对 SGLang `extend` batch：`input_length = req.extend_input_len`；
- 对 SGLang `decode` batch：`input_length = 1`；
- 两种情况都令 `past_kv_length = len(req.prefix_indices) + len(req.output_ids)`。

随后 hook 调用 `INFERENCE_PREDICTOR.predict_infer_time()`。离线模式把预测秒数保存为本轮 `current_inference_dur`；阻塞模式则按预测值等待墙钟时间后记录实际等待时长。真正推进全局模拟时钟发生在后续 `process_batch_result()`：它会根据 overlap 配置，将本轮 inference duration 与 HiCache L2 load/backup 时延串行相加或部分重叠。相关逻辑见 [`sglang_hook.py`](../third_party/tair-kvcache/hisim/src/hisim/simulation/sglang/sglang_hook.py#L792-L877)。

## 3. Prefill/Decode 判定及 `extend_input_len=1` 边界

最终采用哪条预测路径，不是直接读取 SGLang 的 `forward_mode`，而是由 HiSim `ScheduleBatch.is_decode()` 再判定：

```python
for req in self.reqs:
    if req.input_length > 1:
        return False
return True
```

定义见 [`time_predictor/base.py`](../third_party/tair-kvcache/hisim/src/hisim/time_predictor/base.py#L56-L63)。由此产生三个重要边界：

1. batch 中所有请求的 `input_length <= 1` 时，整个 batch 走 Decode；
2. 只要有一个请求的 `input_length > 1`，整个 batch 都走 Prefill；
3. 一个由 SGLang 标记为 `extend` 的 batch，如果其中每个请求恰好只有 `extend_input_len=1`，进入 predictor 后仍会被归入 Decode。

第三点是当前实现的判定语义，而不是“所有 SGLang extend 都是 Prefill”。如果未来需要严格保持 SGLang 的 phase，需要把外层 `forward_mode` 作为显式输入传给 predictor，不能只靠 Token 数推断。

## 4. 当前 Qwen3-8B 实际覆盖的算子

HiSim 的 [`get_perf_model()`](../third_party/tair-kvcache/hisim/src/hisim/time_predictor/aiconfigurator.py#L267-L359) 把 `qwen3` 注册为 AIConfigurator 的 `LLAMA` family。当前容器中 AIConfigurator 的 Qwen/LLAMA dense pipeline 位于 `/opt/venv/lib/python3.10/site-packages/aiconfigurator/sdk/models.py`，实际覆盖下列项目。

| Prefill/Context | Decode/Generation | 估算方式 |
| --- | --- | --- |
| `context_embedding` | `generation_embedding` | HBM memory operation |
| `context_add_norm_1` | `generation_add_nrom_1` | ElementWise memory operation |
| `context_qkv_gemm` | `generation_qkv_gemm` | H20 GEMM 表 |
| `context_attention` | `generation_attention` | H20 Context/Generation Attention 表 |
| `context_proj_gemm` | `generation_proj_gemm` | H20 GEMM 表 |
| `context_add_norm_2` | `generation_add_norm_2` | ElementWise memory operation |
| `context_gate_ffn1_gemm` | `generation_gate_ffn1_gemm` | H20 GEMM 表 |
| `context_act_gate` | `generation_act_gate` | ElementWise memory operation |
| `context_ffn2_gemm` | `generation_ffn2_gemm` | H20 GEMM 表 |
| `context_logits_gemm` | `generation_logits_gemm` | H20 GEMM 表；Token 规模按 batch 而非 `B×s` |
| `context_ar_1/2` | `generation_ar_1/2` | Custom AllReduce；当前 `tp_size=1` 时为 0 |
| `context_p2p` | `generation_p2p` | Pipeline P2P；当前 `pp_size=1` 时为 0 |

AIConfigurator 的 SGLang backend 源码还包含一个条件分支：仅当内部 `model.model_name` 等于 `qwen3_8b` 或含有 `qwen3-8b` 时，才会为每个 Decode step 加入 `generation_inherent_latency`（内部 batch size 不大于 48 时为 `0.8 ms`，大于 48 时为 `1.6 ms`）。当前 SGLang→HiSim 路径从 Hugging Face config 构造 `ModelInfo` 时没有取得匹配名称，而是生成带时间戳的名称，因此实际不会命中该分支。不能把这项固有延迟计入当前 H20 结果。

这是一套算子级延迟聚合，不是实际执行上述 kernel。当前 Qwen3-8B 为 dense 模型，H20 数据包中即使存在 MoE/MLA 表，本路径也不会因此自动执行 MoE 或 MLA 模型公式。

## 5. H20 性能表与带宽公式

H20 数据由 [`scripts/fetch_h20_data.sh`](../scripts/fetch_h20_data.sh) 准备，并由配置中的 `database_path=/opt/hisim-data/aic`、`device_name=h20_sxm` 和 `backend_version=0.5.6.post2` 精确选择。运行时主要使用：

- `gemm_perf.txt`；
- `context_attention_perf.txt`；
- `generation_attention_perf.txt`；
- `h20_sxm.yaml` 中的 HBM、计算、显存和节点参数。

当前数据库模式默认为 `SILICON`。GEMM 从指定 dtype 的 H20 表选择最接近的 `m/n/k` 点；Context Attention 根据 head、完整序列长度和 batch 做表内估算，并按 prefix 占比修正；Generation Attention 会围绕名义 KV 长度 `s` 的 `0.9s` 到 `1.1s` 取 5 个样点，分别估算后取平均，以降低混合长度 batch 使用单点造成的波动。

H20 配置中的主要解析参数为：

```text
HBM bandwidth = 4.022 × 10^12 Bytes/s
HBM empirical scaling factor = 0.8
HBM empirical constant latency = 3 µs
FP16 tensor-core throughput = 1.48 × 10^14 FLOPs/s
H20 memory capacity = 96 GiB
intra-node bandwidth = 4.50 × 10^11 Bytes/s per GPU, one direction
inter-node bandwidth = 2.50 × 10^10 Bytes/s per GPU, one direction
```

对 Embedding、Norm、Activation 等 memory operation，当前 empirical 公式是：

```text
T_mem_ms
  = (transferred_bytes / (4.022e12 × 0.8) + 3e-6) × 1000
```

例如 ElementWise 根据输入读 Bytes 与输出写 Bytes 之和计算；Embedding 根据本轮访问的 embedding Bytes 计算。若使用纯解析 GEMM 模式，则：

```text
T_math_ms = 2 × M × N × K / effective_compute_FLOPs_per_s × 1000
T_memory_ms = tensor_bytes / HBM_bandwidth × 1000
T_GEMM_ms = max(T_math_ms, T_memory_ms)
```

当前 H20 `SILICON` 路径优先使用表中 latency，解析式主要用于 memory operation 和其他显式数据库模式，不能把所有算子简单理解成“Bytes 除以带宽”。

## 6. Decode：不同 batch size 与 XGBoost 校正

当 `ScheduleBatch.is_decode()` 为真时，predictor 计算：

```text
B = batch 中请求数
isl = int(mean(past_kv_length_i))
osl = 2
```

AIConfigurator 对每个 generation operator 使用 batch size `B` 和 KV 长度 `isl+1` 估算一次 Decode step。GEMM 的主要 Token 维度为 `B`，Generation Attention 则同时依赖 `B` 和 KV 长度。

H20 Qwen3-8B 数据目录中包含按 batch size 范围命名的 XGBoost 模型。加载时先按 bucket 宽度、下界和上界排序；预测时选第一个包含当前 `B` 的 bucket，因此专用窄 bucket 优先于宽 bucket。没有覆盖当前 batch size 的模型时，不进行 XGBoost 修正。

选中模型后，每个请求产生两个特征：

```text
[request_present, past_kv_length]
```

特征矩阵补零到该 bucket 的 `max_bs × 2` 后展平。模型输出：

```text
r = AIC_generation_attention_ms / measured_generation_attention_ms
```

代码将：

```text
generation_attention_scale = 1 / max(r, 1e-6)
```

传给 AIConfigurator，只修正 `generation_attention`，不直接缩放 GEMM、ElementWise 或 logits。实现见 [`aiconfigurator.py`](../third_party/tair-kvcache/hisim/src/hisim/time_predictor/aiconfigurator.py#L141-L201) 和 [`predict_infer_time()`](../third_party/tair-kvcache/hisim/src/hisim/time_predictor/aiconfigurator.py#L447-L480)。

因此不同 Decode batch size 同时影响：

- 所有以 `B` 为 Token 规模的 generation operators；
- Generation Attention 的 H20 表查询；
- XGBoost bucket 选择及其 attention 校正值。

源码中的 `B<=48`/`B>48` inherent-latency 档位因当前模型名不匹配而不参与结果；若未来修正模型名传递，这会成为一个新增的 batch size 分段影响，届时需要重新校准。

## 7. Prefill：均值聚合、`B×s` 与 Attention 不均衡修正

当 batch 中至少一个请求 `input_length>1` 时，整个 batch 走 Prefill。设请求 `i` 的新增 Token 数为 `s_i`，已有 KV 长度为 `p_i`，请求数为 `B`：

```text
mean_input = mean(s_i)
mean_past = mean(p_i)

RuntimeConfig.isl = int(mean_past + mean_input)
RuntimeConfig.prefix = int(mean_past)
```

SGLang backend 随后使用：

```text
s = isl - prefix
x = B × s
```

其中 `x` 用于除 logits 外的 Context GEMM、Embedding 和 ElementWise workload；`context_logits_gemm` 使用 `x=B`。由于两处分别取整，严格说 `s=int(mean_past+mean_input)-int(mean_past)`，通常近似平均新增长度。

只用平均长度会抹平 batch 内序列差异。HiSim 因此按 attention 近似 FLOPs 计算一个不均衡修正：

```text
F_avg
  = B × (2 × mean_past + mean_input) × mean_input / 2

F_actual
  = Σ[(2 × p_i + s_i) × s_i / 2]

attention_imbalance_ratio
  = F_actual / F_avg
```

当该比值不低于 `0.4` 时，它被作为 `seq_imbalance_correction_scale` 传入 Context Attention；低于 `0.4` 时回到默认比例 `1.0`。该比例只修正 `context_attention`，不会重新按每个请求分别计算其他算子。公式实现见 [`ctx_attn_flops_ratio_with_avg()`](../third_party/tair-kvcache/hisim/src/hisim/time_predictor/aiconfigurator.py#L430-L445)。

### 两请求示例

假设同一 Prefill batch 有两个请求：

```text
请求 A：s₁=100，p₁=0
请求 B：s₂=300，p₂=100
```

则：

```text
B = 2
mean_input = 200
mean_past = 50
isl = 250
prefix = 50
s = 200
B × s = 400
```

大多数 Context 算子按 400 个聚合 Token 查询；logits GEMM 按 batch size 2 查询。Attention 修正为：

```text
F_avg
  = 2 × (2×50 + 200) × 200 / 2
  = 60,000

F_actual
  = (2×0 + 100) × 100 / 2
  + (2×100 + 300) × 300 / 2
  = 5,000 + 75,000
  = 80,000

attention_imbalance_ratio
  = 80,000 / 60,000
  = 1.3333
```

所以本例的 Context Attention 表估算结果再乘约 `1.3333`，而其他 Context 算子仍使用均值聚合得到的 workload。

## 8. SGLang Chunked Prefill 与 predictor 的分工

Chunked Prefill 的切分由 SGLang Scheduler 完成，不由 AIConfigurator 决定。SGLang 根据 `chunked_prefill_size` 和本轮 Token 预算设置每个请求的 `extend_input_len`；HiSim hook 只读取当前 chunk 的长度和已经存在的 prefix/output 长度。

因此 predictor 每次估算的是“本轮实际进入 SGLang forward 的 chunk”，而不是一次性估算整个原始 prompt：

```text
SGLang：决定哪些请求进入 batch、每个请求本轮处理多少 Token
HiSim hook：把当前 batch 转成 FakeRequest
AIConfigurator：估算这个 batch/chunk 的模型 forward latency
HiSim 时钟：把多轮 chunk、排队和 Decode 迭代累计成请求级指标
```

SGLang 的 chunk 分配和 `extend_input_len` 更新可见 [`schedule_policy.py`](../third_party/sglang/python/sglang/srt/managers/schedule_policy.py)；HiSim 读取当前值的位置见 [`sglang_hook.py`](../third_party/tair-kvcache/hisim/src/hisim/simulation/sglang/sglang_hook.py#L801-L818)。

需要特别保留第 3 节的边界：若某轮所有 chunk 都恰好为 1 Token，当前 HiSim predictor 会按 Decode 处理，即使 SGLang 外层 mode 是 `extend`。

## 9. 最终延迟聚合公式

AIConfigurator 的各算子结果以毫秒保存于 latency dictionary。当前 predictor 的最终公式为：

```text
T_prefill_seconds
  = 1.045 × Σ(context_operator_latency_ms) / 1000

T_decode_seconds
  = 1.0 × Σ(generation_operator_latency_ms) / 1000
```

Decode 的 `generation_attention` 在进入求和前可能已经乘过 XGBoost 给出的 `1/r`；当前路径不包含前述条件式 Qwen3-8B inherent latency。Prefill 的 `context_attention` 在进入求和前可能已经乘过 attention imbalance ratio。

代码顺序是先取得 `get_generation_latency_dict()` 或 `get_context_latency_dict()`，再求和，然后应用 `decode_scale_factor` 或 `prefill_scale_factor`，最后除以 1000。实现见 [`aiconfigurator.py`](../third_party/tair-kvcache/hisim/src/hisim/time_predictor/aiconfigurator.py#L480-L518)。

若 AIConfigurator 判断 OOM，会把总时延改为负值；HiSim predictor 接口用负值表达异常类结果。正常 H20 仿真使用正值推进模拟时钟。

## 10. 结果解释边界

当前链路已经验证：

- H20 数据包、Qwen3-8B 元数据和 XGBoost 模型可以加载；
- SGLang 能形成实际 Prefill/Decode batch 并调用 predictor；
- predictor 输出能够推进 HiSim 时钟并形成完整 benchmark 指标。

当前链路尚未验证：

- 本服务器实体 H20 上相同 Qwen3-8B、SGLang 和 workload 的逐算子误差；
- `1.045` 和 XGBoost attention correction 对本机环境的独立校准精度；
- 模拟吞吐、TTFT、TPOT 与生产真机结果之间的稳定误差区间。

因此，当前 H20 结果应表述为 `official_h20_data_path / INTEGRATION_ONLY`：它证明固定数据与功能路径成功集成，不等于实体 H20 性能实测，也不能直接作为容量规划或 SLA 依据。
