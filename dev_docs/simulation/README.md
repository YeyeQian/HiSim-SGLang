# 仿真文档导航

先从仓库根目录的 [README](../../README.md) 完成 Linux x86_64 CPU-only Docker quickstart。以下文档用于理解实现、结果边界和后续扩展；它们不替代 README 中的可执行操作说明。

## 入门

- [HiSim + SGLang 联合仿真入门](concepts/hisim_sglang_joint_simulation_beginner_guide.md)
- [SGLang 入门](concepts/sglang_beginner_guide.md)

## 实现与内部机制

- [CPU-only Docker 实施报告](reports/implementation_report.md)
- [部署与能力汇报](reports/hisim_sglang_simulation_deployment_report.md)
- [H20 推理时延计算](internals/hisim_h20_inference_latency_calculation.md)

## 对比与评估

- [HiSim 与 llm-ep-simulator 对比](comparisons/hisim_vs_llm_ep_simulator_comparison.md)
- [llm-ep-simulator 参考评估](evaluations/llm_ep_simulator_reference_assessment.md)

所有性能数字均为仿真或历史集成证据，不能当作实体 GPU 实测、独立校准或容量承诺。
