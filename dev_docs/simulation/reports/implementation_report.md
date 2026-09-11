# HiSim + SGLang CPU-only Docker 实施报告

更新日期：2026-09-08

分支：`feature/cpu-docker-smoke`

仓库：`/data/userhome/zhaoyifan/Work/HiSim-SGLang/.worktrees/cpu-docker-smoke`

## 1. 最终结论

本服务器已用 Docker 完成 CPU-only HiSim → SGLang HTTP → benchmark 全链路验证。generic、固定 H20 数据路径和可选 ShareGPT workload 均有成功的 benchmark 与规范化 validator 证据；未观察到真实模型权重加载、真实 model forward、CUDA 初始化或 NCCL communicator 初始化。最终 validator 不再接受 CLI 自报类别：benchmark lifecycle 会在 Docker exec 前写入 `provenance.json`，validator 强制加载并交叉校验 service、dataset、profile 和固定结果类别映射。

结论边界必须保留：

- generic 是 `upstream_generic_mock / NOT_CALIBRATED`，只证明基础链路。
- H20 是 `official_h20_data_path / INTEGRATION_ONLY`，只证明固定官方数据路径可以集成。
- ShareGPT 是 `sharegpt_workload_shape / WORKLOAD_SHAPE_ONLY`，只提供更接近对话的文本和长度分布，不评测回答质量。
- 所有指标都是 HiSim 模拟输出，不能当成服务器实测 GPU 性能、独立校准或容量规划依据。

## 2. 固定源码、补丁与实现 commits

固定上游身份：

| 组件 | 固定值 |
| --- | --- |
| SGLang | `0.5.6.post2` / `5c8bd8b51b53b9b39eb1edec582ee43b21002106` |
| tair-kvcache / HiSim | `a6e5d176c96009ba76c0ebb70e83cfb113fe9e65` |
| AIConfigurator | `9f744a1910f317a091c88ade644d61094ea22119` |
| SGLang CPU fallback 补丁来源 | `2f4a6addf3101342498b4528289c6fd053622530`，stable patch-id `ab5af423a7740bba40e04752e3c54adc747b02fa` |
| LatencyPrism H20 数据 revision | `d242ca5b8d7217e1d235d2fb225ff4a8ba24995a` |
| ShareGPT observed revision | `192ab2185289094fc556ec8ce5ce1e8e587154ca` |

主要交付 commits：

- `c620e2c`：固定上游 submodule 和版本 manifest。
- `91ca8db` 及之前 Task 3 commits：preflight、host helper 与 H20 下载准备。
- `711d209`、`cf40a8d`：固定 CPU dependency/image contract。
- `d360e93`：proxy-aware Docker build 与 image inspection。
- `4b7c77f`、`a54337c`：容器 lifecycle、runtime guard 和 benchmark 证据。
- `718a461` 至 `bbba7fd`：generic validator、metadata、上游 CPU patch、AIConfigurator LFS 数据、离线 profile 与有限网络超时。
- `406d1e3`：固定 H20 数据路径仿真。
- `f8ea450`、`10b0d2c`、`0e41715`：可选 ShareGPT profile 及一次性生命周期清理。
- `bd124f3`：记录 ShareGPT lifecycle review fixes。

完整线性历史以 `git log --oneline feature/cpu-docker-smoke` 为准；上游 pins 由 `configs/versions.env` 和 `tests/test_pins.sh` 机器验证。

## 3. 镜像与依赖证据

最终本地镜像：

- tag：`hisim-sglang-cpu:0.5.6.post2`
- image ID：`sha256:43a15bcf2ef6cd5013bf2154e89776879b1e8eeb7c4540215791f95dc62b877f`
- 创建时间：`2026-09-08T13:30:42.758754617Z`
- 本地 size：`4299757936` bytes
- RepoDigest：空；该镜像只在本机构建，未 push 到 registry，因此不虚构 registry digest。
- 最终 review-fix build：`logs/task7/review-fix-build.exit-code` 为 `0`，完整输出在 `logs/task7/review-fix-build.stdout.log`。

镜像中关键版本：

| 包/运行时 | 版本 |
| --- | --- |
| Python | `3.10.12` |
| torch | `2.9.0+cpu` |
| SGLang | `0.5.6.post2` |
| HiSim | `0.1.0` |
| AIConfigurator | `0.5.0` |
| transformers | `4.57.1` |
| XGBoost | `2.0.3` |
| NumPy | `1.26.4` |
| nvidia-ml-py | `13.610.43` |
| git-lfs | `3.7.1` |

`nvidia-ml-py` 是允许的纯 Python NVML telemetry binding，不提供 CUDA 计算能力。最终 `scripts/inspect_image.sh` 退出 0，并记录：`torch.cuda.is_available(): False`、`/dev/nvidia*: absent`、禁止的 accelerator distributions absent、固定 AIConfigurator commit 与已实体化的 H100 performance data。完整证据位于：

```text
/data/userhome/zhaoyifan/Work/HiSim-SGLang/.worktrees/cpu-docker-smoke/artifacts/image/
/data/userhome/zhaoyifan/Work/HiSim-SGLang/.worktrees/cpu-docker-smoke/logs/task9/inspect-image.stdout.log
```

## 4. 数据资产

H20 archive：

- URL：`https://raw.githubusercontent.com/kunluninsight/LatencyPrism/d242ca5b8d7217e1d235d2fb225ff4a8ba24995a/Hisim/Data/H20_AIC.zip`
- size：`9039139` bytes
- SHA256：`7702dbffe750a9d0f6b7ce547056bfbaa3da5e158ac7fa25e75b057df4792289`
- archive：`/data/userhome/zhaoyifan/Work/HiSim-SGLang/.worktrees/cpu-docker-smoke/artifacts/downloads/H20_AIC.zip`
- 解压 root：`/data/userhome/zhaoyifan/Work/HiSim-SGLang/.worktrees/cpu-docker-smoke/artifacts/h20_aic/aic`

H20 downloader 通过 `proxy_url` 把项目代理显式传给 curl，同时保留 10 秒 connect timeout、60 秒 transfer timeout、三次有限尝试、TLS 校验、size/SHA 校验和原子安装。fixture 测试验证了精确的 `--proxy` 参数转发。

ShareGPT：

- URL：`https://huggingface.co/datasets/anon8231489123/ShareGPT_Vicuna_unfiltered/resolve/main/ShareGPT_V3_unfiltered_cleaned_split.json`
- size：`672837942` bytes（641.67 MiB）
- 实际文件 SHA256：`35f0e213ce091ed9b9af2a1f0755e9d39f9ccec34ab281cd4ca60d70f6479ba4`
- 文件：`/data/userhome/zhaoyifan/Work/HiSim-SGLang/.worktrees/cpu-docker-smoke/artifacts/downloads/ShareGPT_V3_unfiltered_cleaned_split.json`

ShareGPT 下载通过宿主机代理完成；再次运行 downloader 会重新校验并复用。只有 `start_server.sh generic sharegpt` 才把该文件精确只读挂载为 `/opt/hisim-data/sharegpt.json`。基础 `random-ids` smoke 不需要它，因此断网时仍可在已有 image/tokenizer cache 上执行。

## 5. 已完成 benchmark 结果

所有表中 benchmark 和当时 validator exit code 均为 `0`，failed 均为 `0`。Task 7、Task 8 和 ShareGPT 行是 provenance 加固前的历史运行证据；其原始指标、runtime guard 和资源证据仍保留，但最终类别信任边界由 Task 9 review-fix 后重新执行的 fresh generic/H20 以及新静态 lifecycle 测试覆盖。按审查要求未重新执行 ShareGPT live，也未重新下载数据；后续 ShareGPT 运行会自动生成并必须验证 provenance sidecar。

| 类别/profile | completed | duration (s) | req/s | TTFT (ms) | TPOT (ms) | ITL (ms) | peak memory (MiB) | 结果目录 |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | --- |
| generic probe（Task 7） | 2 | 0.0339596583 | 58.8934076764 | 7.3445949815 | 6.6537658262 | 6.6537658262 | 3915.78 | `results/20260908T123654Z-generic-77085` |
| generic small（Task 7） | 16 | 0.2610038379 | 61.3017805839 | 57.4078750318 | 6.7797793075 | 6.7804005951 | 3934.21 | `results/20260908T124025Z-generic-84274` |
| H20 probe（Task 8） | 2 | 0.0336894602 | 59.3657478176 | 7.3329150280 | 6.5891363000 | 6.5891363000 | 4211.71 | `results/20260908T134826Z-h20-79823` |
| H20 small（Task 8） | 16 | 0.5184791489 | 30.8594859297 | 288.8259986451 | 7.6965935509 | 7.6924111978 | 4224.00 | `results/20260908T135531Z-h20-74386` |
| ShareGPT（可选） | 16 | 3.8249078712 | 4.1831072901 | 197.7838956877 | 6.9561259396 | 6.9371336225 | 5056.51 | `results/20260908T143438Z-generic-29090` |
| fresh generic probe（provenance 加固后） | 2 | 0.0339596583 | 58.8934076764 | 7.3445949815 | 6.6537658262 | 6.6537658262 | 3924.99 | `results/20260908T153202Z-generic-57411` |
| fresh H20 probe（provenance 加固后） | 2 | 0.0336894602 | 59.3657478176 | 7.3329150280 | 6.5891363000 | 6.5891363000 | 4219.90 | `results/20260908T153458Z-h20-63247` |

fresh 结果的 benchmark 绝对目录：

```text
/data/userhome/zhaoyifan/Work/HiSim-SGLang/.worktrees/cpu-docker-smoke/results/20260908T153202Z-generic-57411/benchmark/generic/probe/20260908T153341080418171-60934
/data/userhome/zhaoyifan/Work/HiSim-SGLang/.worktrees/cpu-docker-smoke/results/20260908T153458Z-h20-63247/benchmark/h20/probe/20260908T153748540073386-22337
```

两次 provenance 加固后的 fresh probe 均带有执行前生成的 sidecar。generic 映射为 `generic / none / probe / upstream_generic_mock`，H20 映射为 `h20 / none / probe / official_h20_data_path`；两次 validator 都加载 sidecar 后退出 0。cache 均从 `15560 KiB` 变为 `15560 KiB`，delta 为 `0 KiB`；`cache-weight-changes.txt` 均为 0 bytes。ShareGPT 成功运行的 cache delta 也为 `0 KiB`。每个最终服务日志均包含 HiSim config、mock ModelRunner、request barrier 和 simulation results marker；fresh generic 加载 `h100_sxm/sglang/0.5.6.post2`，fresh H20 加载 `h20_sxm/sglang/0.5.6.post2`。禁止运行路径扫描没有命中，且不存在 `guard-failure.txt`。

每个 fresh profile 都使用独立容器。验证后 exact service container 被 stop/remove，active state 目录不存在，`127.0.0.1:30000` 无监听。镜像、cache、数据、日志和结果均保留。

## 6. 最终验证命令与退出状态

执行命令：

```bash
bash scripts/test_all.sh
bash scripts/preflight.sh
bash scripts/inspect_image.sh
git submodule status --recursive
```

Task 9 review-fix 记录：聚合测试 `0`、preflight `0`、image inspection `0`；21 个 Python unit tests 和全部 `tests/test_*.sh` 通过。新增测试明确证明：缺失 provenance 会被拒绝；unlabeled generic-shaped metrics 即使 CLI 声明为 H20 也会被拒绝；三类 lifecycle 映射 sidecar 正确；H20 curl 精确接收项目代理。submodule status 精确报告上述两个固定 commits。日志目录：

```text
/data/userhome/zhaoyifan/Work/HiSim-SGLang/.worktrees/cpu-docker-smoke/logs/task9/
/data/userhome/zhaoyifan/Work/HiSim-SGLang/.worktrees/cpu-docker-smoke/logs/task9-review-fix/
```

fresh generic 与 H20 都依次执行 `start_server.sh`、`wait_ready.sh`、`run_benchmark.sh ... probe`、带 `--provenance` 的 `validate_results.py` 和 `stop_server.sh`，各阶段退出码为 0。具体可复现命令见根目录 `README.md`。

## 7. 资源与网络约束

- service 使用 Docker bridge，只发布 `127.0.0.1:30000`；构建和 metadata/data 下载才显式使用宿主机代理。
- service 限制为 16 CPU、32 GiB memory、4 GiB shm。
- sampled CPU peak 在这些很短的仿真中是 0%，因为 workload 可在相邻 1 秒采样之间完成；该数字不支持 CPU 利用率结论。
- 未修改 Docker daemon、systemd、宿主机 glibc、系统 Python、软件源或其他项目容器。

## 8. 已知限制与后续使用原则

- Qwen3-8B 完整权重没有主动下载；只保存 config/tokenizer。任何真实权重加载或真实 forward 都是 guard failure。
- generic predictor 的 H100 数据来自上游 fixture，不能将 generic 标签改成 H20。
- H20 archive 缺少若干可选 collective tables；固定 `tp_size=1` 路径已通过，但不能外推更复杂并行策略。
- ShareGPT 只改变输入文本与长度分布，HiSim 不产生可评测的语义回答。
- 服务启动的可选 `hf_quant_config.json` 离线检查会产生有界警告和等待，但最终使用缓存 metadata，不触发权重加载。
- 不同 profile 必须使用 fresh server，尤其 ShareGPT 一个 server 只允许一次 benchmark attempt。
