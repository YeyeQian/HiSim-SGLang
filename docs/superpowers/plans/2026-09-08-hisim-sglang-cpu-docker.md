# HiSim + SGLang CPU-only Docker Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build and verify a reproducible CPU-only Docker deployment that runs HiSim through SGLang `0.5.6.post2`, first with the upstream generic mock configuration and then with the pinned H20 AIConfigurator data path.

**Architecture:** A root Git repository owns deployment code, tests, documentation, and immutable upstream references. Pinned SGLang and tair-kvcache source trees are Git submodules; a CPU-only image is built from the SGLang CPU packaging metadata, while host-side shell scripts own proxy-aware build, asset preparation, lifecycle, resource limits, and evidence capture. The service runs in a bridge-networked container published only on host loopback; benchmarks execute inside the same image against that endpoint.

**Tech Stack:** Bash, Docker Engine 20.10, Ubuntu 22.04, Python 3.10+, CPU PyTorch, SGLang `0.5.6.post2`, HiSim, AIConfigurator, Git submodules, curl, sha256sum, unittest-style shell assertions.

**Spec:** `dev_docs/init_pj/hisim_sglang_cpu_docker_confirmed_plan.md`

## Global Constraints

- Pin tair-kvcache/HiSim to `a6e5d176c96009ba76c0ebb70e83cfb113fe9e65`.
- Pin SGLang to `0.5.6.post2` / `5c8bd8b51b53b9b39eb1edec582ee43b21002106`.
- Pin AIConfigurator to `9f744a1910f317a091c88ade644d61094ea22119`.
- Pin LatencyPrism H20 data to commit `d242ca5b8d7217e1d235d2fb225ff4a8ba24995a`; `H20_AIC.zip` SHA-256 is `7702dbffe750a9d0f6b7ce547056bfbaa3da5e158ac7fa25e75b057df4792289`.
- Use `ubuntu:22.04@sha256:3b06811b2afd352be909dd088a004166d665dc76d38b13eada33522a9d915c6f` as the primary base image.
- Keep the image CPU-only: no CUDA Toolkit, NVIDIA container integration, GPU device flags, or ordinary CUDA-dependent SGLang PyPI dependency set.
- Do not change host glibc, system Python, package repositories, Docker daemon configuration, or systemd Docker configuration.
- Do not restart Docker or remove/stop assets outside this project.
- Build/download networking uses host networking plus explicit proxy build arguments; runtime uses bridge networking and publishes only `127.0.0.1:30000` by default.
- Runtime limits are 16 CPUs, 32 GiB memory, and 4 GiB shared memory.
- Do not proactively download Qwen3-8B weights. Permit an upstream-triggered download, but abort if real weights are loaded or a real model forward path executes.
- Generic mock outputs are `SMOKE_TEST_ONLY / NOT_CALIBRATED`; H20 data-path outputs prove integration only, not independent prediction accuracy.
- Stop and remove project test containers after verification; preserve images, sources, caches, logs, configurations, and results.

---

### Task 1: Bootstrap Version Control and Isolated Execution Workspace

**Files:**
- Create: `.gitignore`
- Track: `HISIM_SGLANG_CPU_DOCKER_HANDOFF.md`
- Track: `docker_network_and_proxy_troubleshooting_guide.md`
- Track: `dev_docs/init_pj/hisim_sglang_cpu_docker_confirmed_plan.md`
- Track: `docs/superpowers/plans/2026-09-08-hisim-sglang-cpu-docker.md`

**Interfaces:**
- Consumes: the approved spec and this implementation plan.
- Produces: a clean `main` baseline and an isolated `feature/cpu-docker-smoke` worktree for Tasks 2–9.

- [ ] **Step 1: Initialize the root repository on `main`**

Run:

```bash
git init -b main
git status --short --branch
```

Expected: `## No commits yet on main` plus the existing documents as untracked files.

- [ ] **Step 2: Add repository ignore rules**

Create `.gitignore` with:

```gitignore
.worktrees/
.superpowers/
cache/
results/
logs/
*.log
*.pid
*.env.local
artifacts/h20_aic/
artifacts/downloads/
```

- [ ] **Step 3: Verify generated and isolated paths are ignored**

Run:

```bash
git check-ignore -v .worktrees/example cache/example results/example logs/example artifacts/h20_aic/example
```

Expected: every path is matched by `.gitignore`.

- [ ] **Step 4: Commit the approved baseline**

Run:

```bash
git add .gitignore HISIM_SGLANG_CPU_DOCKER_HANDOFF.md docker_network_and_proxy_troubleshooting_guide.md dev_docs/init_pj/hisim_sglang_cpu_docker_confirmed_plan.md docs/superpowers/plans/2026-09-08-hisim-sglang-cpu-docker.md
git commit -m "docs: record CPU Docker deployment plan"
git status --short
```

Expected: commit succeeds and status is clean.

- [ ] **Step 5: Create and enter the isolated worktree**

Run:

```bash
git worktree add .worktrees/cpu-docker-smoke -b feature/cpu-docker-smoke
git -C .worktrees/cpu-docker-smoke status --short --branch
```

Expected: clean branch `feature/cpu-docker-smoke`.

### Task 2: Pin Upstream Source Trees and H20 Asset Manifest

**Files:**
- Create: `.gitmodules`
- Create: `third_party/tair-kvcache/` as a submodule
- Create: `third_party/sglang/` as a submodule
- Create: `configs/versions.env`
- Create: `configs/assets.sha256`
- Test: `tests/test_pins.sh`

**Interfaces:**
- Consumes: immutable commit and digest values from Global Constraints.
- Produces: `configs/versions.env` variables consumed by download, build, and reporting scripts.

- [ ] **Step 1: Write the failing immutable-pin test**

Create `tests/test_pins.sh`:

```bash
#!/usr/bin/env bash
set -euo pipefail
root_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$root_dir/configs/versions.env"

test "$TAIR_KVCACHE_COMMIT" = "a6e5d176c96009ba76c0ebb70e83cfb113fe9e65"
test "$SGLANG_COMMIT" = "5c8bd8b51b53b9b39eb1edec582ee43b21002106"
test "$SGLANG_VERSION" = "0.5.6.post2"
test "$AICONFIGURATOR_COMMIT" = "9f744a1910f317a091c88ade644d61094ea22119"
test "$LATENCY_PRISM_COMMIT" = "d242ca5b8d7217e1d235d2fb225ff4a8ba24995a"
test "$H20_AIC_SHA256" = "7702dbffe750a9d0f6b7ce547056bfbaa3da5e158ac7fa25e75b057df4792289"
test "$(git -C "$root_dir/third_party/tair-kvcache" rev-parse HEAD)" = "$TAIR_KVCACHE_COMMIT"
test "$(git -C "$root_dir/third_party/sglang" rev-parse HEAD)" = "$SGLANG_COMMIT"
```

- [ ] **Step 2: Run the pin test and confirm the expected failure**

Run: `bash tests/test_pins.sh`

Expected: FAIL because `configs/versions.env` and the submodules do not exist.

- [ ] **Step 3: Add and pin both submodules**

Run:

```bash
git submodule add https://github.com/alibaba/tair-kvcache.git third_party/tair-kvcache
git -C third_party/tair-kvcache checkout a6e5d176c96009ba76c0ebb70e83cfb113fe9e65
git submodule add https://github.com/sgl-project/sglang.git third_party/sglang
git -C third_party/sglang checkout 5c8bd8b51b53b9b39eb1edec582ee43b21002106
```

- [ ] **Step 4: Add the immutable version and asset manifests**

Create `configs/versions.env`:

```bash
TAIR_KVCACHE_COMMIT=a6e5d176c96009ba76c0ebb70e83cfb113fe9e65
SGLANG_COMMIT=5c8bd8b51b53b9b39eb1edec582ee43b21002106
SGLANG_VERSION=0.5.6.post2
AICONFIGURATOR_COMMIT=9f744a1910f317a091c88ade644d61094ea22119
LATENCY_PRISM_COMMIT=d242ca5b8d7217e1d235d2fb225ff4a8ba24995a
H20_AIC_SHA256=7702dbffe750a9d0f6b7ce547056bfbaa3da5e158ac7fa25e75b057df4792289
UBUNTU_2204_IMAGE=ubuntu:22.04@sha256:3b06811b2afd352be909dd088a004166d665dc76d38b13eada33522a9d915c6f
```

Create `configs/assets.sha256`:

```text
7702dbffe750a9d0f6b7ce547056bfbaa3da5e158ac7fa25e75b057df4792289  H20_AIC.zip
```

- [ ] **Step 5: Run the pin test and commit**

Run:

```bash
bash tests/test_pins.sh
git add .gitmodules third_party configs tests/test_pins.sh
git commit -m "build: pin HiSim and SGLang upstream sources"
```

Expected: pin test passes.

### Task 3: Implement Host-Side Validation and H20 Asset Preparation

**Files:**
- Create: `scripts/lib/common.sh`
- Create: `scripts/preflight.sh`
- Create: `scripts/fetch_h20_data.sh`
- Test: `tests/test_common.sh`
- Test: `tests/test_fetch_h20_data.sh`

**Interfaces:**
- Produces: `die`, `require_command`, `require_free_port`, `project_root`, and `proxy_url` shell helpers.
- Produces: verified extracted data under `artifacts/h20_aic/aic/`.
- Consumes: `configs/versions.env` and `configs/assets.sha256`.

- [ ] **Step 1: Write failing helper tests**

Tests must source `scripts/lib/common.sh` and assert:

```bash
test "$(project_root)" = "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
test "$(proxy_url)" = "http://127.0.0.1:17897"
require_command bash
if require_command definitely-not-a-command 2>/dev/null; then exit 1; fi
```

Test `require_free_port` by opening a temporary localhost listener and verifying the helper rejects that port.

- [ ] **Step 2: Run helper tests and confirm failure**

Run: `bash tests/test_common.sh`

Expected: FAIL because `scripts/lib/common.sh` does not exist.

- [ ] **Step 3: Implement minimal common helpers and preflight checks**

`scripts/preflight.sh` must verify, without mutation:

```text
docker, git, curl, sha256sum, unzip, ss
Docker daemon access
proxy listener on 127.0.0.1:17897
at least 40 GiB free under the project filesystem
at least 20 GiB free under DockerRootDir
configured host port is unused
both submodule HEADs match config/versions.env
```

Every failure exits nonzero with one actionable message.

- [ ] **Step 4: Write the failing H20 downloader test using a local fixture**

The test creates a temporary zip containing `aic/data/h20_sxm/sglang/0.5.6.post2/probe.txt`, calculates its checksum, then calls:

```bash
H20_AIC_URL="file://$fixture_zip" \
H20_AIC_SHA256="$fixture_sha" \
H20_AIC_ARCHIVE="$tmp_dir/download/H20_AIC.zip" \
H20_AIC_DIR="$tmp_dir/extracted" \
bash scripts/fetch_h20_data.sh
```

It asserts the probe file exists and a second call is idempotent.

- [ ] **Step 5: Implement checksum-verified atomic asset preparation**

`scripts/fetch_h20_data.sh` must:

```text
download to H20_AIC.zip.partial
verify SHA-256 before rename
extract into a temporary directory
verify aic/data/h20_sxm/sglang/0.5.6.post2 exists
atomically rename the extracted directory
refuse checksum mismatches
avoid deleting a previously verified asset
```

Default URL:

```text
https://raw.githubusercontent.com/kunluninsight/LatencyPrism/d242ca5b8d7217e1d235d2fb225ff4a8ba24995a/Hisim/Data/H20_AIC.zip
```

- [ ] **Step 6: Run tests and commit**

Run:

```bash
bash tests/test_common.sh
bash tests/test_fetch_h20_data.sh
bash scripts/preflight.sh
git add scripts tests
git commit -m "feat: add preflight and verified H20 asset setup"
```

### Task 4: Define and Statically Validate the CPU-only Image

**Files:**
- Create: `Dockerfile`
- Create: `docker/entrypoint.sh`
- Create: `tests/test_dockerfile.sh`

**Interfaces:**
- Consumes: pinned submodules and `AICONFIGURATOR_COMMIT` build argument.
- Produces: image entrypoint commands `server`, `bench`, `versions`, and `shell`.

- [ ] **Step 1: Write the failing Dockerfile policy test**

`tests/test_dockerfile.sh` must assert:

```text
the exact Ubuntu digest is present
SGLANG_USE_CPU_ENGINE=1 is present
FLASHINFER_DISABLE_VERSION_CHECK=1 is present
the CPU pyproject replaces SGLang's ordinary pyproject for installation
the pinned AIConfigurator commit is used
no FROM line names CUDA/NVIDIA images
no apt package name starts with cuda- or nvidia-
no --gpus flag appears
entrypoint has server, bench, versions, shell cases
```

- [ ] **Step 2: Run the Dockerfile test and confirm failure**

Run: `bash tests/test_dockerfile.sh`

Expected: FAIL because `Dockerfile` does not exist.

- [ ] **Step 3: Implement the primary Ubuntu 22.04 CPU image**

The Dockerfile must:

```text
start from the exact pinned Ubuntu digest
install only build/runtime CPU prerequisites
create a Python virtual environment at /opt/venv
install the CPU PyTorch stack from the official CPU wheel index
copy pinned SGLang and replace python/pyproject.toml with pyproject_cpu.toml before installation
build/install SGLang from pinned source without ordinary CUDA package metadata
install AIConfigurator from its pinned commit rather than a moving branch
install HiSim from third_party/tair-kvcache/hisim with --no-deps after its declared dependencies are installed, preventing its moving AIConfigurator branch reference from being resolved again
set CPU-only environment variables
copy docker/entrypoint.sh
run as a non-root application user where compatible with SGLang
```

Do not guess a vLLM dependency. Add it only if build/import evidence proves it is required.

- [ ] **Step 4: Implement the entrypoint contract**

Commands:

```text
server: exec python -m hisim.simulation.sglang.launch_server with model, config, host, port, CPU device, and skipped warmup
bench: exec python -m hisim.simulation.bench_serving with simulation mode and zero warmups
versions: print Python, torch, SGLang, HiSim, AIConfigurator, and platform information
shell: exec bash
```

The `server` command must emit the resolved model/config/host/port without secrets.

- [ ] **Step 5: Run static tests and commit**

Run:

```bash
bash tests/test_dockerfile.sh
git add Dockerfile docker tests/test_dockerfile.sh
git commit -m "build: define CPU-only HiSim SGLang image"
```

### Task 5: Build and Inspect the Image

**Files:**
- Create: `scripts/build.sh`
- Create: `scripts/inspect_image.sh`
- Generate: `artifacts/image/versions.txt`
- Generate: `artifacts/image/pip-freeze.txt`
- Generate: `logs/docker-build.log`
- Test: `tests/test_build_scripts.sh`

**Interfaces:**
- Produces: default image tag `hisim-sglang-cpu:0.5.6.post2`.
- Produces: immutable runtime dependency evidence consumed by README and final report.

- [ ] **Step 1: Write failing build-script contract tests**

Assert `scripts/build.sh` contains and correctly composes:

```text
docker build --network host
uppercase and lowercase HTTP/HTTPS proxy build args
--progress=plain
pipefail-preserved logging
configurable IMAGE_TAG
```

Assert `scripts/inspect_image.sh` rejects any installed distribution whose normalized name starts with `nvidia-`, equals `cuda-python`, `flashinfer-python`, or `flashinfer-cubin`.

- [ ] **Step 2: Run contract tests and confirm failure**

Run: `bash tests/test_build_scripts.sh`

- [ ] **Step 3: Implement build and inspection scripts**

Build failures must preserve the first dependency error. Inspection must run:

```bash
docker run --rm "$IMAGE_TAG" versions
docker run --rm --entrypoint bash "$IMAGE_TAG" -lc 'python -m pip freeze'
docker image inspect "$IMAGE_TAG"
```

Inspection must also prove `/dev/nvidia*` is absent and `torch.cuda.is_available()` is false inside the runtime container.

- [ ] **Step 4: Build the image and diagnose failures systematically**

Run:

```bash
bash scripts/build.sh
bash scripts/inspect_image.sh
```

If Ubuntu 22.04 fails due to a demonstrated toolchain or user-space dependency constraint, add `Dockerfile.ubuntu24` as a separately logged diagnostic fallback. Do not replace `Dockerfile` silently.

- [ ] **Step 5: Freeze the resolved environment and commit**

Copy the successful `pip freeze` output to `configs/requirements.resolved.txt`, rerun inspection, then:

```bash
git add scripts tests configs/requirements.resolved.txt
git commit -m "build: add reproducible image build and inspection"
```

### Task 6: Implement Safe Container Lifecycle and Benchmark Orchestration

**Files:**
- Create: `scripts/start_server.sh`
- Create: `scripts/wait_ready.sh`
- Create: `scripts/run_benchmark.sh`
- Create: `scripts/stop_server.sh`
- Create: `tests/test_lifecycle_scripts.sh`

**Interfaces:**
- Produces: container name `hisim-sglang-cpu-smoke` by default.
- Produces: generic and H20 run directories under `results/<run-id>/`.
- Consumes: image tag, local model cache, simulation config, H20 data directory, and port.

- [ ] **Step 1: Write failing lifecycle policy tests**

Tests must assert the scripts enforce:

```text
--cpus 16
--memory 32g
--shm-size 4g
bridge networking
127.0.0.1:${PORT}:30000 publication
port precheck with fail-on-conflict
read-only source/config/H20 mounts
read-write Hugging Face cache and result mounts
finite readiness and benchmark timeout
only the exact project container name may be stopped or removed
```

- [ ] **Step 2: Run lifecycle tests and confirm failure**

Run: `bash tests/test_lifecycle_scripts.sh`

- [ ] **Step 3: Implement start, readiness, benchmark, and stop scripts**

`run_benchmark.sh` supports exactly these profiles:

```text
probe: 2 prompts, concurrency 1, short input/output
small: 16 prompts, concurrency 4, random input length 256, random output length 32
```

Every invocation stores command metadata, timestamps, stdout, stderr, exit code, and Docker resource samples in its run directory.

- [ ] **Step 4: Add weight-load and real-forward guards**

After a run, scan server logs for concrete model-loading and real-forward indicators. If found, mark the run failed and stop the project container. Record Hugging Face cache size before and after each run without deleting it.

- [ ] **Step 5: Run tests and commit**

Run:

```bash
bash tests/test_lifecycle_scripts.sh
git add scripts tests
git commit -m "feat: add bounded server and benchmark lifecycle"
```

### Task 7: Execute and Validate Generic Mock Smoke Tests

**Files:**
- Create: `scripts/validate_results.py`
- Test: `tests/test_validate_results.py`
- Generate: `results/<run-id>/generic/`

**Interfaces:**
- Consumes: upstream `hisim/test/assets/mock/config.json` unchanged.
- Produces: machine-readable validation summary for probe and small profiles.

- [ ] **Step 1: Write failing result-validator tests**

Fixtures must cover:

```text
valid benchmark output with successful request count, TTFT, TPOT, ITL, throughput, and duration
missing metric
negative required metric
failed request count
NaN or infinity
generic result incorrectly labeled as H20 performance
```

Run: `python3 -m unittest tests/test_validate_results.py -v`

Expected: FAIL because `scripts/validate_results.py` does not exist.

- [ ] **Step 2: Implement the minimal parser and validator**

The validator exits nonzero unless all required metrics are present, finite, nonnegative, and the successful-request count matches the profile. It writes JSON with `status`, `profile`, `completed`, `metrics`, `config_kind`, and `calibration_status`.

- [ ] **Step 3: Start generic server and run both workload profiles**

Run:

```bash
bash scripts/start_server.sh generic
bash scripts/wait_ready.sh
bash scripts/run_benchmark.sh generic probe
bash scripts/run_benchmark.sh generic small
bash scripts/stop_server.sh
```

- [ ] **Step 4: Recreate the container and repeat the probe**

Run the start/wait/probe/stop sequence again and confirm the result validator passes.

- [ ] **Step 5: Commit validator and non-generated metadata**

Run:

```bash
python3 -m unittest tests/test_validate_results.py -v
git add scripts/validate_results.py tests/test_validate_results.py
git commit -m "test: validate generic HiSim serving results"
```

Generated result/log directories remain ignored but are referenced from the final report with absolute paths.

### Task 8: Execute and Validate the H20 Data-Path Smoke Tests

**Files:**
- Create: `configs/h20-qwen3-8b.json`
- Generate: `artifacts/h20_aic/aic/`
- Generate: `results/<run-id>/h20/`
- Test: `tests/test_h20_config.py`

**Interfaces:**
- Consumes: verified H20 archive and upstream `config.qwen8b.aic.json` values.
- Produces: a container-resolved H20 configuration using `/opt/hisim-data/aic` and `/opt/hisim-data/aic/xgb_models/qwen3_8B`.

- [ ] **Step 1: Write the failing H20 configuration test**

The test asserts:

```text
platform accelerator is H20
predictor is aiconfigurator
device_name is h20_sxm
database_path is /opt/hisim-data/aic
xgb_model_path is /opt/hisim-data/aic/xgb_models/qwen3_8B
backend_version is 0.5.6.post2
tp_size is 1
```

- [ ] **Step 2: Run the H20 config test and confirm failure**

Run: `python3 -m unittest tests/test_h20_config.py -v`

- [ ] **Step 3: Download, verify, extract, and configure H20 data**

Run:

```bash
bash scripts/fetch_h20_data.sh
python3 -m unittest tests/test_h20_config.py -v
```

Before launching, verify the backend data directory and Qwen3-8B XGBoost directory both contain files.

- [ ] **Step 4: Run H20 probe and small profiles**

Run:

```bash
bash scripts/start_server.sh h20
bash scripts/wait_ready.sh
bash scripts/run_benchmark.sh h20 probe
bash scripts/run_benchmark.sh h20 small
bash scripts/stop_server.sh
```

If H20 integration fails after generic succeeds, preserve failure evidence and classify the overall result exactly as `framework_smoke_passed_h20_integration_failed`.

- [ ] **Step 5: Commit H20 configuration and tests**

Run:

```bash
git add configs/h20-qwen3-8b.json tests/test_h20_config.py
git commit -m "feat: add pinned H20 data-path simulation config"
```

### Task 9: Document, Re-run, and Review the Complete Delivery

**Files:**
- Create: `README.md`
- Create: `dev_docs/implementation_report.md`
- Create: `scripts/test_all.sh`
- Modify: `.gitignore` only if a generated path was missed

**Interfaces:**
- Consumes: all successful commands, resolved versions, result summaries, and known failures.
- Produces: the final reproducible operator workflow and evidence-backed implementation report.

- [ ] **Step 1: Create the aggregate test runner**

`scripts/test_all.sh` runs every static shell test and Python unit test, then reports a single nonzero exit code on any failure. It does not rebuild the image or rerun networked smoke tests by default.

- [ ] **Step 2: Write the operator README**

Document exact commands for:

```text
submodule initialization
preflight
H20 asset preparation
proxy-aware build
image inspection
generic probe and small smoke tests
H20 probe and small data-path tests
stopping the project container
finding logs/results/caches
overriding port, proxy, image tag, and cache directory
known limitations and NOT_CALIBRATED labels
```

- [ ] **Step 3: Write the evidence-backed implementation report**

Include exact commits, image ID/digest, package versions, build exit code, each benchmark exit code, request success counts, required metrics, cache size delta, peak resource readings, evidence that CUDA and real forward paths were absent, H20 classification, and absolute artifact paths.

- [ ] **Step 4: Run fresh verification**

Run:

```bash
bash scripts/test_all.sh
bash scripts/preflight.sh
bash scripts/inspect_image.sh
git submodule status --recursive
git status --short
```

Then rerun one fresh generic probe and one fresh H20 probe from newly created containers, stopping/removing the container after each.

- [ ] **Step 5: Commit the final delivery**

Run:

```bash
git add README.md dev_docs/implementation_report.md scripts/test_all.sh .gitignore
git commit -m "docs: add reproducible CPU simulation runbook"
git status --short --branch
```

Expected: clean feature branch with all tests passing and generated evidence retained only in ignored directories.
