# GitHub 源码 + Docker 发布设计

## 目标

将项目发布到 `https://github.com/YeyeQian/HiSim-SGLang.git`，使另一台 Linux x86_64 服务器在只需 Git 和 Docker（及脚本使用的少量宿主机基础命令）的前提下，可以克隆源码、在 Docker 内构建所有 Python/C++ 依赖，并运行 generic `random-ids` 全链路验收。

## 发布边界

上传：

- 主项目源码、Dockerfile、配置、补丁、测试和文档。
- 指向固定 commit 的 `third_party/sglang` 和 `third_party/tair-kvcache` Git submodule 引用。
- 默认在可直连互联网的目标服务器上使用的构建与下载脚本；仍保留显式 HTTP 代理覆盖，便于当前服务器开发。

不上传：

- Docker 镜像、Qwen 模型缓存、H20/ShareGPT 数据、日志、仿真结果和其他生成产物。
- `.worktrees/` 及任何现有或新建的 worktree/分支内容副本。
- `third_party/llm-ep-simulator/`；该目录仅是本地参考项目。
- `.local_docs/`；其中保存只适用于当前服务器的网络与代理排障文档。
- GitHub 凭据、代理凭据或其他机密信息。

## 用户体验

README 首先提供一条最短的 generic smoke 路径：

1. `git clone --recurse-submodules ...`
2. 进入仓库。
3. 运行一个 quickstart 脚本，依次执行前置检查、构建镜像、检查镜像、启动 generic 服务、等待就绪、执行 probe benchmark、在 Docker 内验证结果并停止本项目容器。

quickstart 失败时仍应尝试只停止它自己启动的项目容器，保留日志和结果供排查。它不下载 H20 或 ShareGPT 数据，也不下载 Qwen3-8B 完整权重。

## 网络策略

- `DOCKER_PROJECT_PROXY` 未设置、为空值或为 `direct` 时直接连接互联网；这是 GitHub 目标服务器的默认路径。
- 显式的 `http://HOST:PORT` 仍按现有行为使用并验证；当前服务器可显式传入 `http://127.0.0.1:17897`。
- Docker build、H20/ShareGPT 下载和模型 metadata 准备都使用同一网络选择；直连时不注入伪造的 proxy 参数或环境变量。

## 容器化边界

- Python、PyTorch CPU、SGLang、HiSim、XGBoost 等项目依赖全部在 Docker 镜像内安装。
- 宿主机不需要 Python 虚拟环境、CUDA、NVIDIA 驱动或 GPU。
- 宿主机仍需 Docker daemon 权限、Git 和 shell 脚本明确检查的基础工具；发布的 quickstart 不依赖宿主机 Python。
- 服务继续只绑定 `127.0.0.1:30000`，端口占用时失败，不自动改端口。
- 当前 Dockerfile 明确支持 Linux x86_64/amd64，非 amd64 宿主机在前置检查阶段就应获得可理解的失败。

## 兼容性和不变项

- 保持 SGLang `0.5.6.post2`、Qwen3-8B 和 HiSim 功能路径不变。
- 保持 generic/H20/ShareGPT 的结果分类和一个服务生命周期只运行一次 benchmark 的约束。
- 保持 CPU-only 运行保护、容器所有权标签和停止范围。
- 新网络选择和 quickstart 都要有无网络/无 Docker 副作用的 shell 测试。

## 验收

- 所有 `tests/test_*.sh` 和 Python 单元测试通过。
- Shell/Python 语法检查和 `git diff --check` 通过。
- `.dockerignore` 排除 Git 元数据、worktree、本地文档、本地参考仓库和所有生成产物。
- AIConfigurator 的构建获取不依赖分支 tip 仍然指向固定 commit，ShareGPT URL 实际使用已声明的 revision。
- 一次不含已忽略文件的 Git 清单审计证明大文件、缓存、数据和 `llm-ep-simulator` 没有进入提交。
- 本地主分支包含发布变更，功能 worktree/分支保留。
- 向空 GitHub 仓库只推送 `main`；推送前运行最终验证和内容审计。
