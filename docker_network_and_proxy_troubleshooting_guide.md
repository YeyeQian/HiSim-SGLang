# Docker 网络连接与代理排障指南

## 1. 文档目的与适用范围

本文用于本服务器上其他基于 Docker 的项目开发，重点处理以下场景：

- `docker pull`、Dockerfile 中的 `FROM` 无法从 Docker Hub 拉取镜像；
- Dockerfile 中的 `apt-get update`、`curl`、`wget` 等下载失败；
- 容器内访问 GitHub，执行 `git clone`、`git fetch` 或更新 submodule 失败；
- 容器内使用 Conda、pip、SBT、Maven、npm 等下载依赖失败；
- 出现超时、DNS 解析失败、连接重置、TLS/SSL 证书校验失败；
- 访问内网 Registry 或其他内网服务时错误地绕行代理，导致失败或速度异常。

本文基于本机 Chipyard Docker 项目的实际故障和成功记录整理。Chipyard 只是验证案例；诊断方法和命令模板适用于本服务器上的一般 Docker 项目。

本文面向 Linux Docker Engine。Docker Desktop、rootless Docker 和远程 BuildKit 的配置位置可能不同，不能直接套用本文所有宿主机配置命令。

---

## 2. 146 服务器的固定代理约定

在 **146 服务器的 `zhaoyifan` 用户环境**中，已经验证可用的本地代理地址固定为：

```text
http://127.0.0.1:17897
```

建议在每个需要网络下载的 shell 中先设置：

```bash
export DOCKER_PROJECT_PROXY=http://127.0.0.1:17897

export HTTP_PROXY="$DOCKER_PROJECT_PROXY"
export HTTPS_PROXY="$DOCKER_PROJECT_PROXY"
export http_proxy="$DOCKER_PROJECT_PROXY"
export https_proxy="$DOCKER_PROJECT_PROXY"
```

说明：

- 对 146 服务器的 `zhaoyifan` 用户，本文后续命令可直接使用端口 `17897`。
- `HTTP_PROXY` 和 `HTTPS_PROXY` 都使用 `http://` 开头是正常的：它表示客户端通过 HTTP CONNECT 代理建立 HTTPS 隧道，并不表示目标 HTTPS 流量失去加密。
- 同时设置大写和小写变量，可兼容不同下载工具对代理变量大小写的不同处理。
- 该约定不自动适用于其他服务器、其他用户、Docker Desktop 或远程 Docker daemon。
- 代理仍依赖对应代理进程正常运行；端口固定不代表进程永远在线。

开始构建前可以检查：

```bash
env | rg '^(HTTP_PROXY|HTTPS_PROXY|http_proxy|https_proxy)='
ss -ltn | rg ':17897\b'
```

如果端口没有监听，先恢复代理服务；不要通过关闭 TLS 校验来绕过问题。

---

## 3. 核心概念：Docker 存在三条不同的网络路径

同一条 `docker build` 命令可能依次使用不同的网络主体。排障时必须先确定失败属于哪一层。

| 网络层 | 典型操作 | 谁发起请求 | 代理配置位置 |
| --- | --- | --- | --- |
| Docker daemon | `docker pull`、`docker push`、Dockerfile 的 `FROM` | 宿主机上的 `dockerd` | Docker daemon 配置或其 systemd 环境 |
| 镜像构建阶段 | Dockerfile 中的 `RUN apt-get`、`RUN git clone`、`RUN pip install` | BuildKit/构建容器 | `docker build --network` 与 `--build-arg` |
| 运行中容器 | `docker run` 后执行 Git、APT、Conda、SBT 等 | 运行中的容器进程 | `docker run --network` 与 `--env` |

一个层级配置正确，不代表另外两个层级也正确。例如：

- 宿主机 `curl` 能访问 GitHub，不代表 Docker daemon 能拉取 Docker Hub；
- `docker pull ubuntu:22.04` 成功，不代表 Dockerfile 中的 `apt-get update` 成功；
- 镜像构建成功，不代表随后启动的容器自动继承构建时代理；
- 当前 shell 中设置代理，不代表作为 systemd 服务启动的 Docker daemon 会继承它。

---

## 4. 推荐的最短排障流程

遇到网络问题时，按以下顺序进行，不要一开始就反复执行完整构建。

### 4.1 确定失败层级

根据日志中第一个真正失败的位置判断：

- `FROM ...`、`docker pull`、`docker push` 失败：先查 Docker daemon；
- Dockerfile 的某个 `RUN` 失败：先查构建阶段网络；
- 已进入容器后执行下载命令失败：先查运行容器网络；
- 内网 Registry 很慢或无法连接：同时检查 daemon 的 `NO_PROXY` 和 Registry 的 HTTP/TLS 配置。

### 4.2 检查宿主机代理

```bash
export DOCKER_PROJECT_PROXY=http://127.0.0.1:17897

ss -ltn | rg ':17897\b'
curl -I -L --max-time 20 --proxy "$DOCKER_PROJECT_PROXY" https://github.com/
```

`curl` 返回 GitHub 的 HTTP 响应即可证明代理链路基本可用；不要求状态码一定是 `200`，因为重定向或认证挑战也可能产生其他有效状态码。

### 4.3 用小测试复现

先验证一个目标和一个工具。例如，验证容器内 GitHub HTTPS：

```bash
docker run --rm --network host \
  --env HTTP_PROXY=http://127.0.0.1:17897 \
  --env HTTPS_PROXY=http://127.0.0.1:17897 \
  --env http_proxy=http://127.0.0.1:17897 \
  --env https_proxy=http://127.0.0.1:17897 \
  alpine:3.20 \
  sh -lc 'apk add --no-cache curl ca-certificates >/dev/null && curl -I -L --max-time 20 https://github.com/'
```

如果测试镜像本身尚未下载，则这条命令会先使用 Docker daemon 拉取镜像。此时若失败，故障仍属于 daemon 层，而不是容器层。

### 4.4 只修复当前层级并复测

先让最小测试通过，再重试项目中的单个下载步骤，最后才恢复完整构建。

---

## 5. Docker daemon：处理镜像拉取和推送问题

### 5.1 典型现象

```text
Get "https://registry-1.docker.io/v2/": ... Client.Timeout exceeded ...
```

或者 Dockerfile 尚未执行任何 `RUN`，就在 `FROM ubuntu:22.04` 处失败。

这类请求由 Docker daemon 发起。仅在当前用户 shell 中 `export HTTP_PROXY=...` 通常不能改变已经运行的 systemd Docker 服务。

### 5.2 只读检查

```bash
docker info | sed -n '/HTTP Proxy/,+6p;/Registry:/,+6p'
systemctl show docker --property=Environment --no-pager
systemctl cat docker
```

还可以分别检查宿主机通过代理和不通过代理时的外网状态：

```bash
curl -I -L --max-time 20 https://registry-1.docker.io/v2/
curl -I -L --noproxy '*' --max-time 20 https://registry-1.docker.io/v2/
```

Registry 返回 `401 Unauthorized` 往往说明网络和 TLS 已经到达服务端，只是请求没有携带认证；它与连接超时、DNS 失败或证书错误不是同一种故障。

### 5.3 daemon 代理配置

修改 Docker daemon 配置需要 root 权限，并会涉及重启 Docker。执行前应确认不会破坏正在运行的容器。

本服务器既有做法是通过 systemd drop-in 为 Docker 服务设置代理。配置文件通常为：

```text
/etc/systemd/system/docker.service.d/http-proxy.conf
```

示例：

```ini
[Service]
Environment="HTTP_PROXY=http://127.0.0.1:17897"
Environment="HTTPS_PROXY=http://127.0.0.1:17897"
Environment="NO_PROXY=localhost,127.0.0.1,10.134.141.128"
```

修改后：

```bash
sudo systemctl daemon-reload
sudo systemctl restart docker
systemctl is-active docker
systemctl show docker --property=Environment --no-pager
```

注意：

- 修改前先使用 `systemctl cat docker` 检查现有 drop-in，避免覆盖其他管理员配置。
- `127.0.0.1` 对 Docker daemon 表示宿主机自身，因此 daemon 可以访问宿主机本地代理。
- Docker 官方也支持在 `daemon.json` 的 `proxies` 字段中配置代理；不要同时维护互相冲突的多套配置。
- systemd 服务不会自动继承用户登录 shell 的代理变量。
- 如果没有 sudo 权限，应保存上述检查结果并联系管理员，不要自行绕过权限。

### 5.4 内网地址必须合理加入 `NO_PROXY`

内网 Registry、制品库或代码服务器通常应直接访问，避免大文件经外网代理绕行。

146 服务器已验证的一个实际例子是内部 Harbor 地址 `10.134.141.128:9000`。Docker daemon 的 `NO_PROXY` 中应包含相应主机：

```text
localhost,127.0.0.1,10.134.141.128
```

是否包含端口取决于客户端匹配规则。为避免实现差异，已知整台内网主机均应直连时，优先填写主机名或 IP；不要使用过宽的 `*`。

`NO_PROXY` 的遗漏可能表现为：

- 内网 Registry 可连接但上传大层极慢；
- 代理拒绝访问内网地址；
- 认证、重定向或协议判断出现异常。

---

## 6. 镜像构建阶段：APT、GitHub 和依赖下载

### 6.1 146 服务器推荐构建模板

当 Dockerfile 中需要访问 GitHub、Ubuntu 软件源或其他外网依赖源时，使用：

```bash
bash -o pipefail -lc 'docker build \
  --network host \
  --build-arg HTTP_PROXY=http://127.0.0.1:17897 \
  --build-arg HTTPS_PROXY=http://127.0.0.1:17897 \
  --build-arg http_proxy=http://127.0.0.1:17897 \
  --build-arg https_proxy=http://127.0.0.1:17897 \
  --progress=plain \
  -t example/project:dev . 2>&1 | tee docker-build.log'
```

这里两个部分承担不同作用：

- `--network host` 让 Linux 构建容器共享宿主机网络命名空间，因此容器内的 `127.0.0.1:17897` 能到达宿主机代理；
- `--build-arg` 让 Dockerfile 中的 APT、Git、curl、wget、pip 等工具看到代理变量。

如果只传代理变量但仍使用默认 bridge 网络，`127.0.0.1` 会指向构建容器自己，通常无法连接宿主机代理。反过来，只使用 host 网络却不传代理变量，下载工具仍可能直连外网并被校园网关干扰。

`bash -o pipefail` 用于确保 `docker build` 失败时，即使输出经过 `tee`，整条命令仍返回失败状态。

### 6.2 不要把构建代理写成 Dockerfile 的永久 `ENV`

不推荐：

```dockerfile
ENV HTTP_PROXY=http://127.0.0.1:17897
ENV HTTPS_PROXY=http://127.0.0.1:17897
```

原因：

- 代理配置会固化进镜像，换服务器后可能失效；
- 运行容器可能无意间继续使用构建机代理；
- 包含认证信息的代理 URL 可能泄露到镜像配置或历史中。

Docker 对 `HTTP_PROXY`、`HTTPS_PROXY`、`NO_PROXY` 等提供预定义 build args。一般只需在构建命令使用 `--build-arg`，无需在 Dockerfile 中声明或回显它们。

### 6.3 APT 的最小验证

APT 失败时先运行：

```bash
docker run --rm --network host \
  --env HTTP_PROXY=http://127.0.0.1:17897 \
  --env HTTPS_PROXY=http://127.0.0.1:17897 \
  --env http_proxy=http://127.0.0.1:17897 \
  --env https_proxy=http://127.0.0.1:17897 \
  ubuntu:22.04 \
  bash -lc 'apt-get update && apt-get install -y --no-install-recommends ca-certificates git curl make python3 && git --version && curl --version | head -n 1 && python3 --version'
```

通过条件：

- 能下载 Ubuntu 的 `InRelease` 和软件包索引；
- 软件包安装成功；
- 不出现未知签发者、`NOSPLIT`、校园认证网页内容或异常内网握手地址。

### 6.4 为什么安装 `ca-certificates` 不一定能修复 APT TLS 错误

如果错误发生在 `apt-get update`，APT 还没有成功下载软件包索引。此时 `ca-certificates` 本身也依赖同一条失败的下载路径，无法成为启动阶段的万能修复。

本机历史故障中，APT 请求曾实际握手到异常内网地址，并报告未知证书签发者；默认 bridge 或未代理的 host 网络还可能出现 `wlrz.fudan.edu.cn`、`NOSPLIT` 或非 Ubuntu 仓库内容。最终修复是让请求稳定通过宿主机代理到达真实软件源，而不是关闭证书校验。

---

## 7. 运行中容器：GitHub、Conda、pip、SBT 等

### 7.1 146 服务器推荐运行模板

```bash
docker run --rm -it \
  --network host \
  --env HTTP_PROXY=http://127.0.0.1:17897 \
  --env HTTPS_PROXY=http://127.0.0.1:17897 \
  --env http_proxy=http://127.0.0.1:17897 \
  --env https_proxy=http://127.0.0.1:17897 \
  --env NO_PROXY=localhost,127.0.0.1,10.134.141.128 \
  --env no_proxy=localhost,127.0.0.1,10.134.141.128 \
  example/project:dev \
  bash
```

运行中容器不会自动继承上一次 `docker build --build-arg` 的代理设置，因此网络下载容器必须单独传入 `--env`。

使用 host 网络时，容器与宿主机共享网络命名空间，端口发布参数 `-p`/`--publish` 不再生效。仅在需要访问宿主机本地代理或确有其他 host 网络需求时使用它。

### 7.2 GitHub 与 Git

最小只读测试：

```bash
git ls-remote https://github.com/git/git.git HEAD
```

或者：

```bash
curl -I -L --max-time 20 https://github.com/
```

实际下载时保存日志和退出码：

```bash
bash -o pipefail -lc 'git clone https://github.com/OWNER/REPOSITORY.git 2>&1 | tee git-clone.log'
```

对于含 submodule 的项目，主仓库克隆成功并不代表所有 submodule 均可访问。应单独记录：

```bash
bash -o pipefail -lc 'git submodule sync --recursive && git submodule update --init --recursive 2>&1 | tee git-submodule-update.log'
```

不要通过以下方式解决 GitHub TLS 错误：

```bash
git config --global http.sslVerify false
```

该设置会影响该用户后续所有 Git HTTPS 请求，并关闭服务端身份校验。

### 7.3 Conda、pip、SBT、Maven 和 npm

这些工具通常会读取 `HTTP_PROXY`/`HTTPS_PROXY`，但它们访问的域名、证书库、重试策略和缓存各不相同。建议按顺序检查：

1. 容器中是否能看到大小写两组代理变量；
2. `curl` 是否能访问该工具实际使用的仓库域名；
3. 工具日志中的第一个失败 URL 是什么；
4. 故障是网络超时、DNS、HTTP 状态码、TLS，还是版本/依赖解析错误；
5. 是否有某个内网镜像源被错误地放在代理路径上。

常用日志关键词：

```bash
rg -n -i 'timeout|temporary failure|could not resolve|connection reset|connection refused|SSL|TLS|certificate|CondaHTTPError|HTTP 000|502|503|504' build-or-download.log
```

不要把所有依赖解析失败都归因于网络。例如版本冲突、包不存在、Python ABI 不兼容、SBT 插件版本错误，即使与下载同时出现，也需要根据第一个非网络错误单独判断。

---

## 8. 常见错误与判断方法

| 日志现象 | 更可能的原因 | 首选检查 |
| --- | --- | --- |
| `Client.Timeout exceeded while awaiting headers` 出现在 `FROM` | daemon 无法访问 Registry | daemon 代理、DNS、systemd 环境 |
| `apt-get update` 出现未知签发者 | 流量被网关或错误代理路径干扰 | 构建网络和代理，实际响应内容 |
| 出现 `wlrz.fudan.edu.cn` 或认证网页 | 请求被校园网关重定向 | 是否同时使用 host 网络和代理 |
| `Could not resolve host` | DNS 失败或代理未使用 | 容器 DNS、代理变量、代理是否在线 |
| 连接 `127.0.0.1:17897` 被拒绝 | 容器看不到宿主机代理，或代理未监听 | 是否为 host 网络；宿主机 `ss -ltn` |
| GitHub 首页可达，但 clone/submodule 失败 | 特定 GitHub 域名、仓库权限或长连接问题 | 第一个失败 URL、HTTP 状态、凭据 |
| 内网 Registry 上传极慢 | 流量错误地经过代理 | Docker service 的 `NO_PROXY` |
| Registry 返回 `401` | 服务可达但需要认证 | 凭据与权限，而不是网络连通性 |
| `server gave HTTP response to HTTPS client` | Registry 只提供 HTTP，daemon 默认尝试 HTTPS | 管理员确认并最小范围配置 `insecure-registries` |
| `404` 或 package not found | URL、仓库或包版本错误 | 不应先修改代理或 TLS |

---

## 9. APT TLS 证书错误的专项处理

### 9.1 安全结论

遇到以下错误：

```text
Certificate verification failed: The certificate is NOT trusted.
The certificate issuer is unknown.
Could not handshake: Error in the certificate verification.
```

应先怀疑网络出口、校园认证网关、错误代理或 TLS 中间链路，而不是立即修改信任库。

### 9.2 禁止的临时绕过

不要执行：

- 关闭 APT HTTPS 证书校验；
- 设置 `Acquire::https::Verify-Peer=false`；
- 使用 `curl -k` 或 `wget --no-check-certificate` 作为正式解决方案；
- 将来源未知的中间证书直接加入系统信任库；
- 将 Git 的 `http.sslVerify` 全局设为 `false`；
- 把密码、token 或带认证信息的代理 URL写入 Dockerfile、镜像层、仓库或日志。

这些做法会掩盖真正的网络问题，并削弱软件包和源码下载的完整性保护。

### 9.3 何时才考虑导入 CA

只有在网络管理员明确确认存在合规的企业 TLS 检查代理，并提供可验证来源、正确用途和轮换方案的根 CA 时，才考虑导入 CA。操作前需要明确：

- CA 的来源和指纹；
- 导入宿主机、Docker daemon、构建镜像还是语言运行时证书库；
- 影响范围和撤销方式；
- 是否能用正常代理路径避免 TLS 检查。

本机 Chipyard 历史问题不需要导入未知 CA；使用正确代理路径后已成功完成 APT、GitHub、Miniforge、Conda 和后续构建下载。

---

## 10. 内部 HTTP Registry 与外网 TLS 问题不要混淆

内部 Harbor 当前可能以 HTTP Registry 形式提供服务。若出现：

```text
server gave HTTP response to HTTPS client
```

管理员可以在 `/etc/docker/daemon.json` 中对确切的内部 Registry 地址配置最小范围的 `insecure-registries`。示例：

```json
{
  "insecure-registries": ["10.134.141.128:9000"]
}
```

这只适用于经过确认的内部 HTTP Registry，不是解决 GitHub、Docker Hub、Ubuntu APT 或其他公网 HTTPS 证书错误的办法。

修改前必须：

1. 备份并保留 `daemon.json` 中已有字段；
2. 使用 `python3 -m json.tool /etc/docker/daemon.json` 验证 JSON；
3. 确认重启 Docker 对当前容器的影响；
4. 重启后用 `docker info` 检查配置是否生效；
5. 同时检查该内网地址是否应加入 daemon 的 `NO_PROXY`。

---

## 11. 日志、重试与可复现性

### 11.1 保留真实退出码

所有经过 `tee` 的关键命令建议使用：

```bash
bash -o pipefail -lc 'COMMAND 2>&1 | tee operation.log'
```

否则 `COMMAND` 失败而 `tee` 成功时，外层 shell 可能错误地返回成功。

### 11.2 使用普通文件权限保存日志

代理地址、用户名、内网域名本身也可能属于内部信息。日志应保存在项目受控目录，避免全局可读。不要记录：

- 密码、Personal Access Token、JWT；
- `docker login` 的输入；
- 完整 `~/.docker/config.json`；
- 带用户名和密码的代理 URL；
- 私有仓库的秘密凭据。

### 11.3 小步重试

网络故障后推荐：

1. 保留原日志；
2. 检查第一个失败 URL 和错误类别；
3. 运行单一最小测试；
4. 修复对应网络层；
5. 只重试失败的下载或构建步骤；
6. 最小步骤通过后再恢复完整流程。

不要因为一次网络失败就删除整个工作区、Conda 环境、Docker volume 或源码目录。对不完整的 clone，如确需重克隆，应先保留现场并确认目标目录后再操作。

### 11.4 减少对实时外网的依赖

对于构建成本高、上游依赖多或网络长期不稳定的项目：

- 固定基础镜像 tag，重要发布可进一步记录 digest；
- 固定源码 commit/tag 和依赖版本；
- 使用 lockfile；
- 将下载和编译拆成可缓存层；
- 保留 Dockerfile、构建命令和无秘密日志；
- 只有在从外网稳定重建确实困难时，才将经验证的完整镜像归档到内部 Harbor。

缓存和内部镜像提高可复现性，但不能替代来源校验、版本锁定和构建记录。

---

## 12. 146 服务器快速操作清单

### 12.1 新项目首次构建

```bash
export DOCKER_PROJECT_PROXY=http://127.0.0.1:17897
ss -ltn | rg ':17897\b'

bash -o pipefail -lc 'docker build \
  --network host \
  --build-arg HTTP_PROXY=http://127.0.0.1:17897 \
  --build-arg HTTPS_PROXY=http://127.0.0.1:17897 \
  --build-arg http_proxy=http://127.0.0.1:17897 \
  --build-arg https_proxy=http://127.0.0.1:17897 \
  --progress=plain \
  -t PROJECT_NAME:dev . 2>&1 | tee docker-build.log'
```

### 12.2 在容器中下载 GitHub 或依赖

```bash
docker run --rm -it \
  --network host \
  --env HTTP_PROXY=http://127.0.0.1:17897 \
  --env HTTPS_PROXY=http://127.0.0.1:17897 \
  --env http_proxy=http://127.0.0.1:17897 \
  --env https_proxy=http://127.0.0.1:17897 \
  --env NO_PROXY=localhost,127.0.0.1,10.134.141.128 \
  --env no_proxy=localhost,127.0.0.1,10.134.141.128 \
  PROJECT_NAME:dev bash
```

### 12.3 判断 Docker Hub 拉取是否属于 daemon 问题

```bash
docker pull ubuntu:22.04
docker info | sed -n '/HTTP Proxy/,+6p;/Registry:/,+6p'
systemctl show docker --property=Environment --no-pager
```

如果 `docker pull` 失败而宿主机通过 `127.0.0.1:17897` 的 `curl` 测试成功，应重点检查 daemon 代理配置，并联系具备 root 权限的管理员处理。

### 12.4 最终验收

- Docker daemon 能拉取项目所需基础镜像；
- Dockerfile 内的最小 APT 或依赖下载测试成功；
- 运行中容器能访问项目实际使用的 GitHub 和依赖仓库；
- 内网服务没有错误绕行代理；
- 日志没有 TLS 校验关闭、未知 CA 导入或凭据泄露；
- 完整构建命令返回 `0`，且 `tee` 没有掩盖失败码。

---

## 13. 本机验证依据与外部参考

本指南主要整理自以下本地记录：

- `docker_apt_tls_certificate_troubleshooting.md`：APT TLS 证书失败的根因与最小验证方法；
- `chipyard_docker_plan/chipyard_1.11.0_docker_install_plan.md`：host 网络、代理、GitHub、Conda 和分阶段重试方案；
- `chipyard_docker_plan/chipyard_1.11.0_execution_log.md`：Docker Hub 超时、APT/校园网关异常，以及通过 `127.0.0.1:17897` 完成构建、Git clone、Miniforge 和依赖下载的实测记录；
- `archive_docs/v0.5/impls/Harbor推送前_Docker_root配置操作说明.md`：Docker daemon、内部 HTTP Registry 和 `NO_PROXY` 的实际配置经验。

Docker 官方参考：

- [Daemon proxy configuration](https://docs.docker.com/engine/daemon/proxy/)
- [Use a proxy server with the Docker CLI](https://docs.docker.com/engine/cli/proxy/)
- [Build variables: proxy arguments](https://docs.docker.com/build/building/variables/#proxy-arguments)
- [Host network driver](https://docs.docker.com/engine/network/drivers/host/)

---

## 14. 一句话原则

先判断请求由 Docker daemon、构建容器还是运行容器发起，再在对应层配置代理；在 146 服务器的 `zhaoyifan` 用户环境中，访问外网统一优先使用 `--network host` 和显式代理 `http://127.0.0.1:17897`，内网地址则通过精确的 `NO_PROXY` 直连，绝不以关闭 TLS 校验代替网络排障。
