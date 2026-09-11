# HiSim + SGLang CPU-only Docker 仿真

本仓库在无 GPU 服务器上运行固定版本的 HiSim 与 SGLang `0.5.6.post2`。真实的 SGLang HTTP、请求调度与 benchmark 路径仍会运行，但模型计算由 HiSim 替代；它不会执行真实 Qwen3-8B forward，也不会生成可用于质量评测的回答。

已验证的结果类别：

- `upstream_generic_mock / NOT_CALIBRATED`：快速、离线、确定性的 `random-ids` 基础链路 smoke test；上游 generic fixture 实际使用 H100 predictor 数据，不能称为 H20 性能。
- `official_h20_data_path / INTEGRATION_ONLY`：固定 H20 数据包的集成验证，不等于实测 H20 性能、独立校准或容量规划依据。
- `sharegpt_workload_shape / WORKLOAD_SHAPE_ONLY`：可选真实对话文本/长度分布负载，只验证 workload shape，不评估回答质量。

## 快速开始

目标宿主机必须是 Linux x86_64，已安装 Git、Docker Engine（daemon 已运行，当前用户可访问）和 `ss`，并在项目文件系统预留至少 40 GiB、Docker 数据目录预留至少 20 GiB。构建峰值会使用较多 CPU、内存和磁盘；运行容器固定上限为 16 CPU、32 GiB 内存和 4 GiB 共享内存。

```bash
git clone --recurse-submodules <GITHUB_REPOSITORY_URL> HiSim-SGLang
cd HiSim-SGLang
bash scripts/quickstart.sh
```

如果已经 clone 但未初始化子模块，执行 `git submodule update --init --recursive`。quickstart 会检查 pins 和宿主机、从源码构建 CPU-only 镜像、检查镜像、启动 generic 服务、运行离线 probe、校验结果并停止服务；失败时也只清理本次由项目启动的服务容器。首次源码构建需要访问 Ubuntu、PyTorch、GitHub 和 Python 包源，耗时和磁盘占用显著高于后续复用镜像的运行。

所有网络访问默认直连，不会自动读取某台开发服务器的代理。只有所在网络确实需要代理时才显式覆盖，例如：

```bash
DOCKER_PROJECT_PROXY=http://127.0.0.1:17897 bash scripts/quickstart.sh
```

代理地址必须是 `http://HOST:PORT`；不需要代理时省略变量，或显式设置 `DOCKER_PROJECT_PROXY=direct`。

## 1. 初始化与前置检查

所有命令都从仓库根目录执行。初始化固定 commit 的子模块：

```bash
git submodule update --init --recursive
bash tests/test_pins.sh
```

默认网络模式是直连，默认服务端口是仅绑定 loopback 的 `127.0.0.1:30000`。前置检查只读验证 x86_64 架构、Docker、按需代理、磁盘、端口和子模块：

```bash
bash scripts/preflight.sh
```

端口已占用时检查会直接失败，不会自动换端口。不要为本项目修改或重启 Docker daemon。

## 2. 准备 H20 数据并构建镜像

H20 数据下载有固定 revision、大小和 SHA256；已验证的本地 archive 与解压数据会直接复用：

```bash
bash scripts/fetch_h20_data.sh
bash scripts/build.sh
bash scripts/inspect_image.sh
```

构建脚本通过 host network 访问网络，并仅在 `DOCKER_PROJECT_PROXY` 显式设置时传入代理；运行服务使用 Docker bridge。默认镜像标签是 `hisim-sglang-cpu:0.5.6.post2`。检查脚本保存版本、完整 Python 包列表、镜像 inspect 和 CPU-only 运行检查到 `artifacts/image/`。

## 3. 运行 generic smoke test

HiSim offline simulation 按整次服务生命周期统计预期请求数，因此每个 profile 都必须使用全新服务容器。probe 的完整命令为：

```bash
bash scripts/start_server.sh generic
bash scripts/wait_ready.sh
bash scripts/run_benchmark.sh generic probe
bench_dir="$(<results/.state/hisim-sglang-cpu-smoke/last-benchmark-probe)"
python3 scripts/validate_results.py \
  --metrics "${bench_dir}/metrics.json" \
  --provenance "${bench_dir}/provenance.json" \
  --profile probe \
  --config-kind upstream_generic_mock \
  --output "${bench_dir}/validation.json"
bash scripts/stop_server.sh
```

small 必须另起一个全新容器：

```bash
bash scripts/start_server.sh generic
bash scripts/wait_ready.sh
bash scripts/run_benchmark.sh generic small
bench_dir="$(<results/.state/hisim-sglang-cpu-smoke/last-benchmark-small)"
python3 scripts/validate_results.py \
  --metrics "${bench_dir}/metrics.json" \
  --provenance "${bench_dir}/provenance.json" \
  --profile small \
  --config-kind upstream_generic_mock \
  --output "${bench_dir}/validation.json"
bash scripts/stop_server.sh
```

`random-ids` 完全在本地生成 token ID，适合作为不受数据下载和文本采样变化影响的基础验收。

## 4. 运行 H20 数据路径

先执行 `bash scripts/fetch_h20_data.sh`。probe 命令：

```bash
bash scripts/start_server.sh h20
bash scripts/wait_ready.sh
bash scripts/run_benchmark.sh h20 probe
bench_dir="$(<results/.state/hisim-sglang-cpu-smoke/last-benchmark-probe)"
python3 scripts/validate_results.py \
  --metrics "${bench_dir}/metrics.json" \
  --provenance "${bench_dir}/provenance.json" \
  --profile probe \
  --config-kind official_h20_data_path \
  --output "${bench_dir}/validation.json"
bash scripts/stop_server.sh
```

small 使用相同流程，但仍须全新启动，并把 `probe` 改为 `small`。

## 5. 可选 ShareGPT 数据与 profile

ShareGPT 文件约 642 MiB，只在宿主机通过代理下载一次。脚本按固定大小和实际文件 SHA256 验证，成功文件保存在 `artifacts/downloads/` 并可重复复用：

```bash
bash scripts/fetch_sharegpt_data.sh
bash scripts/start_server.sh generic sharegpt
bash scripts/wait_ready.sh
bash scripts/run_benchmark.sh generic sharegpt
bench_dir="$(<results/.state/hisim-sglang-cpu-smoke/last-benchmark-sharegpt)"
python3 scripts/validate_results.py \
  --metrics "${bench_dir}/metrics.json" \
  --provenance "${bench_dir}/provenance.json" \
  --profile sharegpt \
  --config-kind sharegpt_workload_shape \
  --output "${bench_dir}/validation.json"
bash scripts/stop_server.sh
```

只有显式的 `generic sharegpt` 启动会把宿主机文件只读绑定到 `/opt/hisim-data/sharegpt.json`。一个 ShareGPT 服务只允许一次 benchmark 尝试；失败、超时或错误 profile 会清理该项目容器，重新运行必须启动新容器。普通 generic/H20 smoke 不依赖 ShareGPT，始终保留 `random-ids` 作为快速离线基线。

## 6. 测试、停止与产物位置

静态 shell 测试和 Python 单元测试的聚合入口不会构建镜像或执行网络 smoke：

```bash
bash scripts/test_all.sh
```

随时只停止本项目当前记录的服务容器：

```bash
bash scripts/stop_server.sh
```

保留的产物：

- `results/<UTC-run-id>/`：服务日志、Docker inspect、benchmark 命令、原始指标、验证结果、资源采样和 cache 差异。
- 每个 benchmark 目录的 `provenance.json`：由 lifecycle 在执行 benchmark 前写入的 service kind、dataset profile、benchmark profile 与期望结果类别；validator 必须读取并与 CLI 交叉校验。
- `logs/`：构建、TDD 和阶段验证日志。
- `cache/huggingface/`：Qwen3-8B config/tokenizer 缓存；不包含主动下载的完整权重。
- `artifacts/h20_aic/` 与 `artifacts/downloads/H20_AIC.zip`：H20 数据与 archive。
- `artifacts/downloads/ShareGPT_V3_unfiltered_cleaned_split.json`：可选 ShareGPT 数据。
- `artifacts/image/`：镜像版本与 CPU-only 检查证据。

## 7. 可覆盖配置

```bash
DOCKER_PROJECT_PROXY=http://127.0.0.1:17897 bash scripts/preflight.sh
HISIM_PORT=30001 bash scripts/start_server.sh generic
IMAGE_TAG=my-hisim:cpu bash scripts/build.sh
IMAGE_TAG=my-hisim:cpu bash scripts/inspect_image.sh
HISIM_IMAGE=my-hisim:cpu bash scripts/start_server.sh generic
HF_CACHE_DIR=/absolute/path/to/hf-cache bash scripts/start_server.sh generic
```

同一生命周期的 `start_server.sh`、`wait_ready.sh`、`run_benchmark.sh` 和 `stop_server.sh` 必须使用一致的 `HISIM_PORT`、`HISIM_CONTAINER_NAME`、`RESULTS_ROOT` 与 `HF_CACHE_DIR` 覆盖值。

如需跳过 quickstart 的一键流程，可按以下生命周期手动运行；每个 benchmark profile 都必须使用全新服务容器：

```bash
bash scripts/preflight.sh
bash scripts/build.sh
bash scripts/inspect_image.sh
bash scripts/start_server.sh generic
bash scripts/wait_ready.sh
bash scripts/run_benchmark.sh generic probe
bench_dir="$(<results/.state/hisim-sglang-cpu-smoke/last-benchmark-probe)"
bash scripts/validate_results.sh "${bench_dir}" probe upstream_generic_mock
bash scripts/stop_server.sh
```

## 8. 已知限制

- 容器限制为 16 CPU、32 GiB memory、4 GiB shm，仅发布到 `127.0.0.1`。
- 镜像允许 `nvidia-ml-py` 这个纯 Python NVML telemetry binding；不包含 CUDA Toolkit、CUDA PyTorch、cuDNN、NCCL、FlashInfer 或 NVIDIA 设备接入。
- 固定 SGLang CPU 路径使用来自上游后续 commit 的三处 CPU fallback 补丁，SGLang submodule pin 未改变。
- 服务启动可能对可选的 `hf_quant_config.json` 做有界离线检查并输出警告；它不会因此加载模型权重。
- H20 archive 缺少部分可选 collective 表，`tp_size=1` 的固定测试仍可集成；这不支持外推其他并行配置。
- sampled CPU 为 0% 可能只是短仿真发生在采样间隔之间，不能解释为没有 CPU 工作。
- 当前证据只覆盖 Qwen3-8B、固定版本和给定服务器环境，不应外推到其他模型、SGLang 版本或硬件预测精度。
- Docker 镜像只提供 x86_64 源码构建路径；仓库不发布预构建镜像，首次构建必须能访问固定上游源码和依赖源。

更深入的架构、实现和评估材料见 [仿真文档导航](dev_docs/simulation/README.md)。
