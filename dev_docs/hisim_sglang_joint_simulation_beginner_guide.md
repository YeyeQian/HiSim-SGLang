# HiSim + SGLang 联合仿真新手说明

## 一句话概括

当前项目用真实的 SGLang 服务和调度流程处理请求，但把最昂贵的“Qwen3-8B 在 GPU 上计算”替换为 HiSim 的耗时预测。

可以把它想象成一家“虚拟餐厅”：

- SGLang 是餐厅前台和调度员：接单、排队、拼单、安排处理顺序。
- Qwen3-8B 是菜单所代表的模型结构。
- HiSim 是厨房模拟器：不真正做菜，而是根据订单复杂度、批次大小和目标硬件数据，预测每道菜要花多久。
- benchmark 是测试顾客：按照指定速度、并发量和文本长度发出订单，并统计等待时间。

## 1. 一次联合仿真是怎么运行的

```text
random-ids / ShareGPT 请求
          │
          ▼
 benchmark 客户端
          │ 真实 HTTP 请求
          ▼
 SGLang HTTP 服务
          │
          ├─ 请求接收、排队、batch 调度
          │
          ▼
 HiSim Hook 拦截模型计算
          │
          ├─ 不加载完整 Qwen3-8B 权重
          ├─ 不执行真实 forward
          ├─ 不调用 CUDA/GPU kernel
          └─ 根据 batch、Token 数和硬件数据预测耗时
          │
          ▼
 模拟 Token 返回时间
          │
          ▼
 TTFT、TPOT、吞吐量等结果
```

这里有一个非常重要的区别：

| 环节 | 是否真实执行 |
| --- | --- |
| Docker 容器启动 | 是 |
| SGLang HTTP 服务 | 是 |
| benchmark 发 HTTP 请求 | 是 |
| SGLang 请求队列和 batch 调度 | 是 |
| ShareGPT 文本采样与 Token 长度 | 是 |
| Qwen3-8B 完整权重加载 | 否 |
| Qwen3-8B 神经网络 forward | 否 |
| H20/H100 GPU kernel 执行 | 否 |
| 推理耗时 | HiSim 预测 |
| 回答内容与语义质量 | 不评测 |

因此它测试的是“推理服务的性能形态”，不是“大模型是否回答正确”。

## 2. 当前支持哪些负载

服务配置和 workload profile 是两个不同维度。

### 2.1 `probe`：最小健康检查

配置：

- 2 个请求
- 并发 2
- 每个请求约 16 个输入 Token
- 生成约 8 个输出 Token
- 使用本地 `random-ids`

它主要回答：

> Docker、HiSim、SGLang HTTP、benchmark、结果验证这一整条链路是否通了？

类似于网站上线后先请求一次 `/health`，确认系统基本可用。

### 2.2 `small`：小规模并发测试

配置：

- 16 个请求
- 并发 16
- 每个请求约 256 个输入 Token
- 生成约 32 个输出 Token
- 使用本地 `random-ids`

它比 `probe` 更容易触发：

- 请求排队
- batch 合并
- 多请求并发
- prefill 和 decode 调度
- 请求间延迟差异

例如可以观察：16 个请求同时到来时，首 Token 延迟是否因为排队而增加。

### 2.3 `sharegpt`：真实对话形态

配置：

- 从约 642 MiB 的 ShareGPT 数据集中抽取对话
- 16 个请求
- 并发 16
- 固定随机种子
- 最大上下文长度 4096
- 当前只搭配 `generic` 服务

ShareGPT 的价值是：真实对话的长短并不整齐。有的提问很短，有的上下文很长，这比固定 256 Token 的 `random-ids` 更接近真实用户负载。

但它仍然只用于模拟：

- 文本长度分布
- 输入/输出 Token 规模
- 请求调度压力
- workload shape

它不评测模型回答内容，因为 HiSim 没有真正运行 Qwen3-8B。

## 3. 当前有哪两种仿真配置

### 3.1 Generic 配置

结果标记为：

```text
upstream_generic_mock / NOT_CALIBRATED
```

这是上游提供的测试配置，内部实际引用 H100 predictor 数据。

它适合：

- 验证整个程序链路
- 做快速回归测试
- 检查代码修改是否破坏 SGLang/HiSim 集成

它不适合：

- 宣称 H100 的真实性能
- 和 H20 做正式性能比较
- 用于生产容量规划

### 3.2 H20 配置

结果标记为：

```text
official_h20_data_path / INTEGRATION_ONLY
```

当前配置是：

- 模型：Qwen3-8B
- SGLang：`0.5.6.post2`
- 目标设备数据：H20
- 数据类型：FP16
- KV Cache 数据类型：FP16
- `tp_size=1`
- predictor：AIConfigurator

它证明的是：

> HiSim 可以正确加载固定的 H20 数据包，并用它驱动 SGLang 仿真。

但目前不能直接宣称：

> 一张真实 H20 一定能达到仿真中的吞吐量。

因为本项目尚未用本服务器上的真实 H20 测量结果独立校准预测误差。

## 4. 能输出和解释哪些指标

### 4.1 TTFT：首 Token 延迟

TTFT 是 Time To First Token。

它表示从请求到达，到用户看到第一个输出 Token 所需的时间。

例如：

```text
TTFT = 300 ms
```

可以理解成用户点击“发送”后，大约 0.3 秒开始看到回答。

它通常受这些因素影响：

- 请求排队
- prompt 长度
- prefill 计算
- 同时到达的请求数量
- batch 调度

### 4.2 TPOT：每个输出 Token 的平均时间

TPOT 是 Time Per Output Token，不包含第一个 Token。

例如：

```text
TPOT = 8 ms
```

粗略表示开始输出后，每隔约 8 毫秒产生一个 Token。TPOT 越低，回答“吐字”越快。

### 4.3 ITL：相邻 Token 间隔

ITL 是 Inter-Token Latency。

它关注相邻两个 Token 之间等待了多久。除了平均值，上游结果还可能包含中位数、P95、P99 和最大值。

ITL 可以帮助观察输出是否平稳。例如平均很快，但 P99 很高，可能意味着偶尔会出现明显停顿。

### 4.4 E2E Latency：端到端延迟

这是从请求开始到完整回答结束的总时间。

它近似受到以下因素共同影响：

```text
排队 + TTFT + 后续所有输出 Token 的耗时
```

### 4.5 Throughput：吞吐量

包括：

- 每秒完成请求数，`req/s`
- 每秒处理输入 Token 数，`tok/s`
- 每秒生成输出 Token 数，`tok/s`
- 总 Token 吞吐量

它描述的是整个服务的处理能力，而不是单个用户的等待体验。

### 4.6 完成和失败请求数

当前 validator 会确认：

- `completed` 符合 profile 预期
- `failed = 0`
- 关键指标存在
- 指标不能是负数、NaN 或无穷大
- 结果类别与实际启动的服务、数据集和 profile 一致

此外，项目还保存：

- 服务日志
- Docker 配置
- benchmark 完整命令
- CPU/内存采样
- Hugging Face cache 前后变化
- 是否意外下载模型权重
- 是否出现真实 forward、CUDA 或 NCCL 初始化
- 结果来源 `provenance.json`

## 5. 一个具体例子：H20 probe

已经完成的一次 H20 probe 仿真结果为：

- 请求数：2
- 失败数：0
- 并发数：2
- 输入长度：约 16 Token
- 输出长度：约 8 Token
- 模拟 duration：约 `0.03369 s`
- 吞吐量：约 `59.37 req/s`
- 平均 TTFT：约 `7.33 ms`
- 平均 TPOT：约 `6.59 ms`
- 平均 ITL：约 `6.59 ms`

正确解读是：

> 在固定 Qwen3-8B、SGLang 0.5.6.post2、`tp_size=1` 和官方 H20 数据路径下，HiSim—SGLang 联合仿真成功处理了两个短请求，并生成了完整、合法的模拟性能指标。

错误解读是：

> 真实 H20 部署 Qwen3-8B 一定可以达到 59.37 req/s。

这是一个非常小的集成 probe，不是生产负载，也不是真实 GPU 测量。

## 6. 再举一个排队例子

假设有 16 个用户同时提问，每个问题约 256 Token，并要求输出 32 Token。

`small` profile 会：

1. 向 SGLang 同时发送 16 个请求。
2. SGLang 决定哪些请求进入同一个 batch。
3. HiSim 根据 batch 中的请求数量、输入长度和 decode 状态预测每轮耗时。
4. 模拟 Token 逐步完成。
5. benchmark 汇总 TTFT、TPOT、ITL 和吞吐量。

之前的 H20 small 结果中：

- 完成 16 个请求
- 吞吐量约 `30.86 req/s`
- 平均 TTFT 约 `288.83 ms`
- 平均 TPOT 约 `7.70 ms`

与两个请求的 probe 相比，TTFT 明显增加。直观上可以理解为：更多请求同时到达后，用户需要经历更多排队和 batch 调度。

但这个例子只能用于理解仿真趋势，暂时不能作为真实 H20 的 SLA。

## 7. 当前最适合用它做什么

目前最可靠的用途有：

- 验证 CPU-only HiSim → SGLang HTTP → benchmark 全链路。
- 在没有 GPU 的服务器上开发和调试 SGLang/HiSim 集成。
- 检查代码更新是否破坏请求、调度或指标输出。
- 验证 H20 predictor 数据包能否正确加载。
- 比较短请求、长请求和不同并发负载下的模拟趋势。
- 使用 ShareGPT 构造更接近真实对话长度分布的压力。
- 保存可复现的日志、配置、数据来源和运行证据。
- 在真正占用 GPU 做昂贵实验前，先筛选值得进一步验证的方案。

## 8. 当前不能用它做什么

当前不能可靠回答：

- Qwen3-8B 的回答是否正确。
- 模型是否会产生幻觉。
- CPU 上真实运行 Qwen3-8B 有多快。
- 一张真实 H20 能承载多少生产用户。
- H20 和 H100 的真实性能差距是多少。
- 能否直接满足某个生产 SLA。
- 多卡 TP、EP 或多节点部署的精确性能。
- 功耗、显存碎片、驱动故障和真实 GPU kernel 抖动。
- 其他模型或其他 SGLang 版本的性能。

上游 HiSim 声称其特定 H20/Qwen3 场景预测误差低于 5%，但这是上游测试结论；当前本服务器项目只验证了数据与功能路径，没有独立复现这个精度结论。

## 9. 延伸阅读

- [项目操作说明](../README.md)
- [实施与验证报告](implementation_report.md)
