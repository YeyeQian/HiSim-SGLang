# HiSim + SGLang 无 GPU 仿真：背景与开发交接

更新日期：2026-09-07  
目标服务器：`server146`（SSH 别名：`146_zyf_server`）  
目标项目：[Alibaba Tair KVCache HiSim](https://github.com/alibaba/tair-kvcache/tree/main/hisim)

## 1. 目标

在没有 GPU 的服务器上，使用 HiSim 的 **Mock Simulation（Inference Simulation）** 功能，对 SGLang 推理服务进行框架在环仿真，评估以下指标和行为：

- TTFT、TPOT、ITL、吞吐量和请求完成时间；
- SGLang 请求队列、连续批处理和调度行为；
- Radix Cache / HiCache 命中及多级缓存行为；
- 真实请求 Trace 回放或随机合成负载；
- 以 H20 等 GPU 为目标硬件进行性能预测，但宿主机本身不需要 GPU。

这里的“混合仿真”指：

> 真实的 SGLang HTTP、请求处理、调度和缓存控制路径 + HiSim 模拟的模型计算与 KV Cache 数据路径。

它不是 CPU 上的真实大模型推理，也不会生成语义正确的模型回答。

## 2. 已完成的项目研究

HiSim 会启动 SGLang 服务，并通过动态 Hook 替换 SGLang 内部的部分实现：

- `ModelRunner.initialize/forward/sample` 被替换，避免加载并执行真实模型；
- GPU Kernel 加载在无 GPU 环境中被拦截；
- 真实 KV Cache 内存池被 Mock 内存池替换；
- SGLang Scheduler 继续运行，并由 AIConfigurator 为每个 batch 预测延迟；
- Blocking 模式通过等待注入预测延迟，Offline 模式通过仿真时钟推进；
- benchmark 客户端仍通过 SGLang HTTP API 发请求，输出格式兼容 `sglang bench_serving`。

相关实现：

- [HiSim README](https://github.com/alibaba/tair-kvcache/blob/main/hisim/README.md)
- [launch_server.py](https://github.com/alibaba/tair-kvcache/blob/main/hisim/src/hisim/simulation/sglang/launch_server.py)
- [sglang_hook.py](https://github.com/alibaba/tair-kvcache/blob/main/hisim/src/hisim/simulation/sglang/sglang_hook.py)
- [sglang_mock_class.py](https://github.com/alibaba/tair-kvcache/blob/main/hisim/src/hisim/simulation/sglang/sglang_mock_class.py)
- [SGLang Simulator Roadmap](https://github.com/sgl-project/sglang/issues/21891)

### 2.1 可行性结论

以下需求可实现：

- 无 GPU 启动 HiSim Mock Simulation；
- 保留单实例 SGLang 调度和缓存控制路径；
- 回放实际 Trace 或使用随机 workload；
- 模拟目标 GPU 的 TTFT、TPOT 和吞吐量；
- 模拟配置中的 TP/EP 等并行开销。

以下能力不能按现成功能处理：

- 生成真实、语义正确的模型输出；
- 用 Mock Simulation 验证模型精度或算子正确性；
- 未经性能数据和校准就可靠预测任意模型、任意硬件；
- SGLang Gateway 多后端实例联合仿真；
- 完整的 PD（Prefill/Decode）分离、跨实例传输和复杂路由；
- 将真实 GPU 节点与 Mock 节点直接混合成生产集群。

### 2.2 当前建议的受支持组合

第一次验证应优先固定在官方已经验证的组合：

- SGLang：`0.5.6.post2`
- 模型：Qwen3-8B（首先使用）
- 目标硬件：H20-96GB
- Predictor：AIConfigurator
- 数据：官方 H20 AIConfigurator 性能数据库和对应校准/XGBoost 数据

仓库当前源码的 Hook 兼容列表包含 SGLang `0.5.6` 到 `0.5.9`，但 README 和公开精度结果仍以 `0.5.6.post2` 为基准。Hook 能运行不等于对应版本已有可信的性能数据库，因此首次部署不要直接采用最新版 SGLang。

版本实现参考：[version.py](https://github.com/alibaba/tair-kvcache/blob/main/hisim/src/hisim/simulation/sglang/version.py)

### 2.3 性能数据库是关键依赖

HiSim 是否“能启动”和预测结果是否“可信”是两个问题。可信度主要取决于：

- 目标硬件的算子性能数据库；
- `backend_version` 与数据库版本是否一致；
- 模型架构是否被 AIConfigurator 支持；
- prefill/decode scale factor 和 XGBoost 校准模型；
- workload 与采集/校准场景是否接近。

仓库测试用 `test/assets/mock/config.json` 不能直接视为生产级可信配置。已有公开问题显示，缺少或版本不匹配的 AIConfigurator 数据库会导致服务初始化失败：[Issue #99](https://github.com/alibaba/tair-kvcache/issues/99)。

官方 README 指向的 H20 数据来源是 [LatencyPrism 的 HiSim 数据目录](https://github.com/kunluninsight/LatencyPrism/tree/hisim)。部署时需要取得对应数据包，并把配置文件中的占位路径改为容器内实际路径。

## 3. 资源需求判断

HiSim 不加载完整的 Qwen3-8B/32B 权重，也不分配真实尺寸的 KV Cache，因此不需要几十 GB 模型内存或 GPU 显存。

大致资源建议：

- 最低：4 CPU 核、8 GB 内存；
- 推荐：8 CPU 核、16 GB 内存；
- 大 Trace、超长上下文或高并发：16–32 GB 内存；
- 磁盘：建议预留 10–20 GB，用于镜像、Python/SGLang 依赖、tokenizer 和性能数据库。

示例：40K 上下文、2048 个请求槽的 request-to-token 表约为：

```text
2048 × 40960 × 4 bytes ≈ 320 MiB
```

实际总内存还包括 PyTorch、SGLang 多进程、tokenizer、AIConfigurator、XGBoost 和 workload 数据，通常为数 GB，而不是完整模型推理所需的几十 GB。

## 4. 目标服务器检查结果

用户已经登录服务器并完成以下检查。

### 4.1 CPU 与指令集

执行：

```bash
lscpu | grep -E 'Architecture|Model name|Flags'
```

关键结果：

```text
Architecture: x86_64
Model name: Intel(R) Xeon(R) Gold 5318Y CPU @ 2.10GHz
Flags: ... avx ... avx2 ... avx512f ... avx512dq ... avx512bw ... avx512vl ...
```

判断：CPU 架构合适，AVX2 和 AVX-512 均可用。HiSim 不执行真实的大规模矩阵计算，因此没有 AMX 不构成阻塞。

### 4.2 内存

执行：

```bash
free -h
```

结果：

```text
              total        used        free      shared  buff/cache   available
Mem:           251G         44G        6.1G        9.9G        200G        196G
Swap:          8.0G        613M        7.4G
```

判断：应看 `available=196G`，不是只看 `free=6.1G`。可用内存远超 HiSim 需求。

### 4.3 宿主机操作系统

执行：

```bash
cat /etc/os-release
```

结果：

```text
Red Hat Enterprise Linux Server 7.5 (Maipo)
```

判断：RHEL 7.5 用户空间较老，通常伴随 glibc 2.17、旧 GCC 和旧系统 Python。直接在宿主机安装新版本 PyTorch、SGLang、XGBoost 等依赖存在明显兼容风险。采用 Docker 隔离新的用户空间，保持宿主系统不变。

### 4.4 Docker 与宿主机内核

执行：

```bash
docker --version
uname -r
```

结果：

```text
Docker version 20.10.24, build 297e128
3.10.0-862.el7.x86_64
```

判断：Docker 版本可以运行普通 Ubuntu 容器。宿主机内核较老，Docker 不能替换宿主内核，因此少数现代依赖仍可能遇到内核兼容问题，但 HiSim 不依赖 CUDA、GPU 驱动或新 GPU 内核功能。

### 4.5 Ubuntu 22.04 镜像检查

执行：

```bash
docker image inspect ubuntu:22.04 >/dev/null 2>&1 \
  && echo "本地已有 ubuntu:22.04 镜像" \
  || echo "本地没有 ubuntu:22.04 镜像"
```

结果：

```text
本地已有 ubuntu:22.04 镜像
```

### 4.6 最小容器兼容性测试

执行：

```bash
docker run --rm ubuntu:22.04 bash -lc \
  'uname -r; uname -m; grep -m1 -o "avx2\|avx512f" /proc/cpuinfo'
```

结果：

```text
3.10.0-862.el7.x86_64
x86_64
avx2
avx512f
```

判断：

- Ubuntu 22.04 容器可以正常启动；
- 容器架构为 x86-64；
- AVX2、AVX-512 在容器内可见；
- 基础 Docker 兼容性检查通过。

## 5. 当前总体结论

目标服务器适合运行 HiSim CPU-only Docker 仿真：

- CPU：满足且明显高于需求；
- 内存：充足；
- GPU：不需要；
- Docker：可用；
- Ubuntu 22.04 镜像：已存在并通过启动测试；
- 风险：宿主机 Linux 3.10 内核较旧，需要在实际安装和启动阶段继续验证现代依赖兼容性。

当前尚未完成：

- 尚未构建 HiSim Docker 镜像；
- 尚未安装或验证 SGLang CPU 版本；
- 尚未取得并挂载 H20 AIConfigurator 数据；
- 尚未启动 HiSim server；
- 尚未执行端到端 benchmark；
- 尚未验证预测结果的可信度。

## 6. 下一次 Codex 会话的开发任务

下一次会话应在服务器上的独立工作目录继续，目标是实现一套可复现的 CPU-only Docker 运行方案。

建议按以下顺序推进，每一步以命令成功退出和预期输出出现为完成条件：

1. 检查当前工作目录、磁盘空间、Docker 权限和网络访问，不修改宿主机系统库。
2. 获取 `alibaba/tair-kvcache` 仓库并记录准确 commit SHA。
3. 研究并固定与 HiSim 相容的 SGLang `0.5.6.post2` CPU 安装方式及 Python/PyTorch 版本。
4. 创建 CPU-only `Dockerfile`，基础镜像优先选择 Ubuntu 22.04；不加入 CUDA/NVIDIA 依赖。
5. 安装 HiSim、SGLang CPU 所需依赖及 AIConfigurator；构建过程保持版本固定、可复现。
6. 取得官方 H20 AIConfigurator/校准数据，挂载到容器中并修正配置路径。
7. 使用 Qwen3-8B 作为首个 smoke test，避免一开始扩大模型范围。
8. 启动服务时设置：

   ```bash
   export SGLANG_USE_CPU_ENGINE=1
   export FLASHINFER_DISABLE_VERSION_CHECK=1
   ```

   并优先传递：

   ```text
   --device cpu --skip-server-warmup
   ```

9. 容器运行时建议设置 `--shm-size=4g`，不要使用 `--gpus`。
10. 先用少量随机请求验证 server、HTTP 请求链路和 benchmark；再使用真实 Trace。
11. 记录实际安装错误、版本、启动日志、峰值内存、结果指标和限制。
12. 完成后交付：`Dockerfile`、构建命令、运行命令、配置文件、benchmark 脚本和 README。

## 7. 开发期间的关键约束

- 保持 CPU-only，不把真实模型推理当作目标。
- 不升级或替换宿主机 glibc。
- 使用 Docker 隔离依赖。
- 首轮固定 SGLang `0.5.6.post2`，只有在基线跑通后再测试其他版本。
- 不把仓库自带测试配置的成功运行等同于预测准确。
- `backend_version`、目标硬件名和 AIConfigurator 数据目录必须相互匹配。
- 模型仓库仍可能需要下载 Hugging Face 配置和 tokenizer；Mock 模式预计不需要完整模型权重，但应通过下载日志和磁盘变化进行验证。
- 遇到 Linux 3.10 内核兼容问题时，应优先调整容器内依赖版本；不要修改宿主系统核心库。
- 对任何“已经完成/可用”的结论都运行端到端 smoke test 后再确认。

## 8. 建议给新 Codex 会话的首条指令

可在服务器的新 Codex 会话中发送：

```text
请完整阅读 HISIM_SGLANG_CPU_DOCKER_HANDOFF.md，并以其中的服务器检查结果、技术约束和下一步任务为准继续开发。目标是在当前服务器上完成 HiSim + SGLang 0.5.6.post2 的 CPU-only Docker 环境，先用 Qwen3-8B 和少量随机请求做端到端 smoke test。请先检查工作目录及现有文件，制定可验证的实施方案，再创建 Dockerfile、配置和运行脚本。不要修改宿主机 glibc，不要引入 CUDA/GPU 依赖，不要在没有端到端测试证据时声称完成。
```
