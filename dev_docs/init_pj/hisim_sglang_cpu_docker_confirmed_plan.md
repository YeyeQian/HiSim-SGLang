# HiSim + SGLang CPU-only Docker 部署确认记录

更新日期：2026-09-08  
状态：方案已确认，实际实施暂缓  
目标服务器：`server146`

## 1. 文档目的

本文记录 HiSim + SGLang 无 GPU Docker 仿真项目在实施前已经确认的目标、技术基线、执行边界和验收条件。

当前仅完成方案确认。按照用户指令，暂不执行以下操作：

- 不初始化 Git 仓库；
- 不添加或拉取 Git submodule；
- 不创建 Dockerfile、配置或运行脚本；
- 不构建镜像；
- 不启动容器或服务；
- 不运行 benchmark。

后续只有在用户明确要求开始实施后，才按本文方案执行。

## 2. 第一阶段目标

第一阶段只证明以下 CPU-only 框架在环链路可以端到端运行：

```text
HiSim Mock Simulation
    -> SGLang HTTP 服务与调度路径
    -> HiSim benchmark client
    -> 指标结果与运行证据
```

第一阶段不是以下目标：

- 不执行真实大模型 CPU 推理；
- 不验证模型输出语义或模型精度；
- 不把 generic mock 输出解释为 H20 性能；
- 不仅凭服务启动或镜像构建成功就宣称全链路完成；
- 不在缺少校准验证的情况下宣称预测结果可用于容量规划或硬件比较。

## 3. 固定技术基线

### 3.1 上游版本

| 组件 | 固定版本或 commit |
| --- | --- |
| tair-kvcache / HiSim | `a6e5d176c96009ba76c0ebb70e83cfb113fe9e65` |
| SGLang | `0.5.6.post2` / `5c8bd8b51b53b9b39eb1edec582ee43b21002106` |
| AIConfigurator | `9f744a1910f317a091c88ade644d61094ea22119` |
| LatencyPrism H20 数据来源 | `d242ca5b8d7217e1d235d2fb225ff4a8ba24995a` |
| 首个模型 | `Qwen/Qwen3-8B` |
| 首选容器系统 | Ubuntu 22.04 |

上游源码和依赖不得在构建时跟随可移动的 branch HEAD。所有实际使用版本均须记录准确 commit、包版本和下载来源。

### 3.2 CPU-only 边界

- 使用 SGLang 官方 CPU 源码构建路径和 `pyproject_cpu.toml`；
- 不使用普通 SGLang PyPI 安装路径引入 CUDA、FlashInfer 或 NVIDIA 运行依赖；
- 不安装 CUDA Toolkit、NVIDIA Container Toolkit 或 GPU 驱动组件；
- 设置 `SGLANG_USE_CPU_ENGINE=1`；
- 设置 `FLASHINFER_DISABLE_VERSION_CHECK=1`；
- 优先使用 `--device cpu` 和 `--skip-server-warmup`；
- HiSim Hook 必须成功替换真实模型执行路径。

### 3.3 兼容性退让边界

- 保持 SGLang `0.5.6.post2`、Qwen3-8B 和 HiSim Mock Simulation 路径不变；
- 允许基于错误证据调整容器内 Python、CPU PyTorch、XGBoost 等依赖的精确版本；
- Ubuntu 22.04 为主基线；如果明确证据表明其工具链或依赖无法满足官方 CPU 构建路径，允许用独立的备用 Dockerfile 测试 Ubuntu 24.04；
- Ubuntu 24.04 不得静默取代 Ubuntu 22.04，两个方案的结果必须分别记录；
- 如果实测证明 CPU-compatible vLLM kernels 是必要依赖，再寻找、验证并锁定稳定版本或 commit；
- 不直接采用最新版或 nightly vLLM；
- 如果必须修改 HiSim 或 SGLang 上游源码才能继续，应先停止并提交根因、最小复现和补丁建议，取得授权后再修改；
- 不修改宿主机 glibc、系统 Python、核心库或软件源。

## 4. 项目目录与版本管理

实施时允许将当前目录初始化为独立 Git 仓库。

规划目录结构如下：

```text
HiSim-SGLang/
├── dev_docs/
├── third_party/
│   ├── tair-kvcache/       # 固定 commit 的 Git submodule
│   └── sglang/             # 固定 commit 的 Git submodule
├── cache/
│   └── huggingface/        # 不纳入 Git，不烘焙进镜像
├── configs/
├── scripts/
├── results/
├── Dockerfile
└── README.md
```

版本管理要求：

- `tair-kvcache` 和 `sglang` 使用 Git submodule，并固定到本文指定 commit；
- AIConfigurator 安装来源固定到准确 commit；
- Ubuntu 基础镜像同时记录 tag 与 digest；
- Python 包记录解析后的精确版本和实际 wheel/source 来源；
- 大模型缓存、下载文件、日志和生成结果通过 `.gitignore` 排除；
- 保留不含凭据的构建与测试日志；
- 最终提供一条构建命令和一条端到端测试命令；
- 代理地址、缓存路径和端口允许通过环境变量覆盖，不永久固化进镜像。

## 5. Docker 网络与代理方案

服务器的本地 HTTP 代理为：

```text
http://127.0.0.1:17897
```

### 5.1 构建和下载阶段

- 使用 `--network host`，使构建容器能够访问宿主机 loopback 上的代理；
- 通过 `--build-arg` 显式传递大小写两组 `HTTP_PROXY` 和 `HTTPS_PROXY`；
- 不把代理写成 Dockerfile 中的永久 `ENV`；
- 关键构建命令使用 `pipefail` 保存真实退出码；
- 网络错误先判断属于 Docker daemon、构建容器还是运行容器，再处理对应层级。

### 5.2 正式运行阶段

- 使用 Docker bridge 网络；
- 默认宿主机端口为 `127.0.0.1:30000`；
- 如果端口已被占用，启动脚本直接失败并给出提示，不自动选择随机端口；
- 端口允许通过环境变量覆盖，但始终只发布到宿主机 loopback；
- 因 Docker NAT 需要，服务可在容器网络命名空间内监听 `0.0.0.0`；宿主机发布范围不得扩大；
- 不依赖 Docker Compose，因为当前服务器未安装 Compose；
- 用户不要求额外开展安全加固工作，但本机访问和非公开服务边界保持不变。

## 6. 宿主机和 Docker 操作边界

除非用户之后单独授权，否则禁止：

- 重启 Docker daemon；
- 修改 `/etc/docker/daemon.json`；
- 修改 Docker systemd drop-in；
- 停止或删除其他用户、其他项目的容器；
- 清理不属于本项目的镜像、volume、缓存或构建资产；
- 修改宿主机 glibc、系统 Python、核心库或软件源。

遇到 daemon 层网络问题时，应先保存只读检查证据并向用户报告，不自行修改系统服务。

## 7. 容器资源限制

首轮服务容器使用以下上限：

| 资源 | 上限 |
| --- | --- |
| CPU | 16 CPU |
| 内存 | 32 GiB |
| shared memory | 4 GiB |

首轮不进行 NUMA 调优。只有在完成基础链路且观察到明确的跨 NUMA 问题后，才另行评估。

## 8. 模型资产策略

- 默认只获取 Qwen3-8B 的公开配置和 tokenizer；
- 不主动预下载完整模型权重；
- 如果上游正常路径意外触发完整权重下载，允许下载完成以避免把下载本身误判为阻塞；
- 下载资产保存在宿主机项目目录下的 `cache/huggingface`；
- 模型缓存通过 bind mount 提供给容器，不烘焙进 Docker 镜像；
- 下载前后记录缓存目录磁盘占用和实际文件；
- 如果出现真实权重加载、真实 CPU model forward 或其他真实模型计算迹象，立即终止测试，因为这意味着 HiSim Hook 未按预期生效；
- smoke test 后保留缓存，未经用户再次确认不删除。

## 9. 配置与 H20 数据路径

### 9.1 Generic mock

先使用上游 `test/assets/mock/config.json` 验证基础链路。

该配置存在以下不一致：

- `platform.accelerator.name` 为 `H20`；
- `predictor.device_name` 为 `h100_sxm`。

因此其结果只能命名为：

```text
upstream generic mock smoke result
```

不得称为 H20 性能结果。保留一份未修改的上游配置；如需生成运行配置，只允许调整路径或增加明确说明，不得伪造硬件一致性。

### 9.2 H20 数据路径 smoke test

generic mock 通过后，执行第二级 H20 数据路径测试：

- 使用固定 LatencyPrism commit 中的 `H20_AIC.zip`；
- 使用 `config.qwen8b.aic.json`；
- 将 `database_path` 和 `xgb_model_path` 的占位路径改为容器内真实只读挂载路径；
- 验证 `device_name=h20_sxm`；
- 验证 `backend_version=0.5.6.post2`；
- 保存数据文件来源、大小和校验值。

该结果标记为：

```text
official H20 data-path smoke result
```

它证明官方数据路径可以集成，但不自动等于已经完成独立精度校准，也不能直接用于容量规划。

如果 generic mock 通过而 H20 数据路径失败，则结论应为：

- CPU-only 框架全链路 smoke test 通过；
- H20 数据集成失败；
- 不宣称 H20 仿真可用；
- 保存 H20 失败的完整证据和后续建议。

## 10. Smoke workload

使用两级合成 workload：

### 10.1 短探针

- 请求数：2；
- 并发：1；
- 使用短输入和短输出；
- 用于验证服务启动、HTTP 返回和基本完成状态。

### 10.2 小型并发测试

- 请求数：16；
- 最大并发：4；
- 目标输入长度：约 256 tokens；
- 目标输出长度：约 32 tokens；
- 记录 tokenizer 生成的实际参数；
- 足以触发请求队列与批处理路径，但不作为性能压测。

benchmark 必须使用：

```text
--bench-mode simulation
--warmup-requests 0
```

所有下载、构建、服务启动和 benchmark 步骤都设置有限超时。网络下载可有限重试；依赖解析、服务启动和 benchmark 不无限重试。

## 11. 第一阶段通过条件

端到端测试必须同时满足：

1. 镜像成功构建，构建命令退出码为 0；
2. 服务在限定时间内就绪；
3. SGLang HTTP API 正常响应；
4. benchmark 退出码为 0；
5. 所有请求完成，无失败请求；
6. TTFT、TPOT、ITL、吞吐量和请求完成时间字段存在；
7. 上述目标指标为有限、非负数；
8. 日志证明 HiSim Hook 生效；
9. 未初始化 CUDA 或 NVIDIA 运行路径；
10. 未加载真实模型权重；
11. 未执行真实 CPU model forward；
12. 容器未突破 16 CPU、32 GiB RAM 和 4 GiB shm 上限；
13. 记录构建、启动、测试日志和峰值资源；
14. 删除并重新创建容器后，测试仍可复现。

仅镜像构建成功、端口监听或单个 HTTP 请求成功，均不足以判定第一阶段完成。

## 12. 失败处理

- 保留第一个真实失败位置、命令、退出码和日志；
- 只终止本项目创建的进程或容器；
- 不通过 `tee` 掩盖失败退出码；
- 不通过关闭 TLS 校验、导入未知 CA 或禁用 Git SSL 校验绕过网络问题；
- 不因一次失败删除整个工作区、模型缓存或 Docker 资产；
- 允许测试多个兼容的 Python、CPU PyTorch 和 XGBoost 精确版本；
- 不自动升级或降级 SGLang；
- 不使用无法追溯的 nightly 包；
- 如果全部合理兼容路径均失败，交付最小复现、失败证据和明确阻塞点，不伪称完成。

## 13. 测试结束后的状态

完成 smoke test 后：

- 停止并移除本项目测试容器；
- 保留构建完成的镜像；
- 保留源码 submodule；
- 保留配置、脚本、README、日志和结果；
- 保留 Hugging Face 缓存；
- 保留 H20 数据包及解压后的只读数据；
- 提供固定命令供用户重新构建和启动；
- 未经用户再次确认，不执行清理或删除操作。

## 14. 预期交付物

实际实施完成后，应交付：

- Git 管理的项目目录；
- 固定上游 commit 的 submodule；
- CPU-only Dockerfile；
- 如确有必要，独立的 Ubuntu 24.04 备用 Dockerfile；
- 精确依赖版本记录；
- generic mock 和 H20 数据路径配置；
- 构建、启动、停止、端口检查和 benchmark 脚本；
- 项目 README；
- 无秘密的构建与运行日志；
- generic mock 与 H20 数据路径的测试结果；
- 峰值内存和资源记录；
- 已知限制、失败项及后续建议。

## 15. 开始实施的前置条件

本文只记录已经确认的方案，不构成当前立即实施指令。

开始实施需要用户在后续消息中再次给出明确授权，例如：

```text
请按照已确认方案开始实施。
```
