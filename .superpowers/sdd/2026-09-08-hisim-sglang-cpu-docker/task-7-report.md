# Task 7 Report: Generic Mock Full-chain Smoke

## Status

`DONE`

CPU-only HiSim → SGLang HTTP → benchmark is proven with the pinned generic mock configuration. Probe and small ran in separate fresh containers because HiSim offline simulation stores an invocation-wide request barrier in server state. Both validators returned `PASS`; all results are labeled `upstream_generic_mock` and `NOT_CALIBRATED`.

## Commits

- `718a461` — `test: validate generic HiSim serving results`
- `3031ab6` — `fix: prepare model metadata through host proxy`
- `2b77cbd` — `fix: harden metadata preparation cleanup`
- `811c68f` — `fix: apply upstream non-AMX CPU fallbacks`
- `9d48739` — `fix: apply CPU patch outside worktree metadata`
- `2b47c5a` — `fix: apply CPU patch from source parent`
- `fd17117` — `fix: materialize AIConfigurator performance data`
- `dc40ebf` — `fix: materialize complete H100 performance data`
- `8740a28` — `fix: align offline simulation benchmark profiles`

Pinned upstream identities remain unchanged:

- SGLang source: `5c8bd8b51b53b9b39eb1edec582ee43b21002106`, version `0.5.6.post2`
- HiSim/tair-kvcache: `a6e5d176c96009ba76c0ebb70e83cfb113fe9e65`
- AIConfigurator: `9f744a1910f317a091c88ade644d61094ea22119`
- CPU compatibility patch provenance: SGLang `2f4a6addf3101342498b4528289c6fd053622530`

## Validator TDD

- Red: `logs/task7/tdd-red.log`, exit 1 for the expected missing implementation.
- Green: `logs/task7/tdd-green.log`, exit 0; 12 tests passed.
- Command: `python3 -m unittest tests/test_validate_results.py -v`.

The validator is grounded in pinned HiSim's single-record JSONL fields: `duration`, `completed`, `request_throughput`, `mean_ttft_ms`, `mean_tpot_ms`, and `mean_itl_ms`. It derives failed requests from the fixed profile count and rejects wrong counts, missing/negative/non-finite metrics, failures, and calibrated/H20 labeling for generic results.

## Debug and compatibility history

### Initial live attempts

1. `results/20260908T110349Z-generic-31538`: start 0, wait 1, cleanup 0. Bridge runtime could not reach the host-loopback proxy for Qwen metadata.
2. `results/20260908T110800Z-generic-38691`: start 0, then deliberately stopped for metadata-helper hardening.
3. `results/20260908T111128Z-generic-46918`: metadata 0, start 0, wait 1, cleanup 0. HiSim hook activated, then pinned SGLang used a vLLM fallback on a non-AMX CPU and raised `ModuleNotFoundError: vllm`.

The final metadata path uses the exact helper `hisim-sglang-cpu-smoke-metadata`, host networking, explicit proxy variables, metadata/tokenizer-only APIs, a finite timeout, ownership label, redacted evidence, and full-ID cleanup. The formal service remains bridge-networked and offline.

An exploratory vLLM empty-package build was terminated with exit 143 and removed because it only masked the first fallback. Evidence: `logs/task7/vllm-build.stdout.log` and `logs/task7/vllm-build.exit-code`.

### SGLang CPU patch

The tracked patch `patches/sglang/2f4a6add-cpu-fallbacks.patch` applies only the three relevant activation, layernorm, and rotary hunks from the authoritative later SGLang commit. The submodule pin is unchanged. Evidence includes:

- `logs/task7/upstream-cpu-fix-evidence.log`
- `logs/task7/upstream-patch-tdd-red.log`
- `logs/task7/upstream-patch-tdd-green.log`
- `logs/task7/patch-no-index-tdd-red.log` / `patch-no-index-tdd-green.log`
- `logs/task7/patch-parent-dir-tdd-red.log` / `patch-parent-dir-tdd-green.log`

### AIConfigurator and Git LFS

`results/20260908T114754Z-generic-94096` reached the HiSim predictor but failed with `KeyError: gemm_dtype`. The installed performance tables were Git LFS pointer text. The final build:

- Downloads Git LFS 3.7.1 with three bounded attempts.
- Verifies SHA256 `1c0b6ee5200ca708c5cebebb18fdeb0e1c98f1af5c1a9cba205a4c0ab5a5ec08`.
- Shallow-clones only `h20e-higher-acc`, whose verified tip equals the pinned AIConfigurator commit.
- Uses `GIT_LFS_SKIP_SMUDGE=1`, then selectively pulls `src/aiconfigurator/systems/data/h100_sxm/**`.
- Requires the H100 directory to exist and rejects every remaining `.txt` LFS pointer before installation and during image inspection.

Build/debug evidence:

- `logs/task7/lfs-build.stdout.log`: APT proxy 502, exit 100.
- `logs/task7/lfs-build-attempt-2.stdout.log`: repeated APT proxy 502, exit 100.
- `logs/task7/lfs-build-attempt-3.stdout.log`: early ARG placement invalidated expensive cache and again hit APT 502, exit 100.
- `logs/task7/lfs-build-attempt-4.stdout.log`: invalid copied SGLang worktree affected `git lfs install`, exit 2.
- `logs/task7/lfs-build-attempt-5.stdout.log`: `--skip-repo` was insufficient in that working directory, exit 2.
- `logs/task7/lfs-build-attempt-6.stdout.log`: full-history clone was stopped after no progress, exit 143.
- `logs/task7/lfs-build-attempt-7.stdout.log`: automatic full LFS smudge was stopped, exit 143.
- `logs/task7/lfs-build-attempt-8.stdout.log`: exposed the missing `src/` path and a false-positive negated grep, exit 0 but rejected by inspection/debug review.
- `logs/task7/lfs-build-attempt-9.stdout.log`: correct version-specific selective pull, exit 0.
- `logs/task7/lfs-build-attempt-10.stdout.log`: complete H100 selective pull, exit 0; final accepted image.
- `logs/task7/aiconfigurator-shallow-branch-evidence.log`: branch-tip provenance.
- `logs/task7/h100-image-inspect.stdout.log`: final image inspection, exit 0.

Image inspection proves AIConfigurator commit and Git LFS version, materialized H100 data, `torch.cuda.is_available(): False`, absence of `/dev/nvidia*`, and absence of forbidden CUDA/cuDNN/NCCL/FlashInfer distributions. `nvidia-ml-py` remains explicitly allowed as a pure Python NVML telemetry binding; it does not supply NVIDIA computation capability.

### Benchmark-specific failures and TDD

`results/20260908T121545Z-generic-38533` progressed past GEMM but failed on an unmaterialized NCCL table (`KeyError: nccl_dtype`), motivating the complete H100 pull.

`results/20260908T122030Z-generic-46669` became ready. Its first probe failed because pinned `--dataset-name random` downloads ShareGPT from a proxy-isolated container. `random-ids` is a pinned, supported mode that generates token IDs locally. The next probe was deliberately terminated after exposing an offline-simulation barrier deadlock: two requests were expected while concurrency was one. A retry on the same server was also terminated because the earlier request had polluted the global counter. The server was then removed.

Regression evidence:

- `logs/task7/random-ids-tdd-red.log` / `random-ids-tdd-green.log`
- `logs/task7/simulation-concurrency-tdd-red.log` / `simulation-concurrency-tdd-green.log`
- Final profiles: probe `2 prompts / concurrency 2`; small `16 prompts / concurrency 16`.

## Final benchmark results

### Probe, fresh container

- Run directory: `/data/userhome/zhaoyifan/Work/HiSim-SGLang/.worktrees/cpu-docker-smoke/results/20260908T123654Z-generic-77085`
- Benchmark directory: `/data/userhome/zhaoyifan/Work/HiSim-SGLang/.worktrees/cpu-docker-smoke/results/20260908T123654Z-generic-77085/benchmark/generic/probe/20260908T123902391862366-81044`
- start 0; wait-ready 0; benchmark 0; validator 0; stop 0.
- completed 2; failed 0.
- duration 0.033959658286188535 s.
- throughput 58.893407676407755 requests/s.
- TTFT 7.344594981492079 ms; TPOT 6.653765826174114 ms; ITL 6.653765826174114 ms.
- validation: `PASS`, `upstream_generic_mock`, `NOT_CALIBRATED`.

### Small, separate fresh container

- Run directory: `/data/userhome/zhaoyifan/Work/HiSim-SGLang/.worktrees/cpu-docker-smoke/results/20260908T124025Z-generic-84274`
- Benchmark directory: `/data/userhome/zhaoyifan/Work/HiSim-SGLang/.worktrees/cpu-docker-smoke/results/20260908T124025Z-generic-84274/benchmark/generic/small/20260908T124308169084432-90354`
- start 0; wait-ready 0; benchmark 0; validator 0; stop 0.
- completed 16; failed 0.
- duration 0.26100383785908315 s.
- throughput 61.30178058392556 requests/s.
- TTFT 57.4078750318271 ms; TPOT 6.779779307512356 ms; ITL 6.780400595072268 ms.
- validation: `PASS`, `upstream_generic_mock`, `NOT_CALIBRATED`.

## Hook, guard, cache, and resources

Both final server logs contain `[hisim] Using config`, `Model runner initialized`, `All requests received. Starting simulation now`, and `Simulation results saved`. Neither log matches the lifecycle guard for weight loading, real model forward, CUDA initialization, or NCCL communicator initialization. No `runtime-guard-failure.txt` exists.

Both benchmark `cache-weight-changes.txt` files are empty. Resource evidence exists in each benchmark directory; observed peaks were 3915.78 MiB for probe and 3934.21 MiB for small. Container inspect evidence records bridge networking, 16 CPUs, 32 GiB memory, 4 GiB shared memory, and `127.0.0.1:30000` publication.

## Verification and cleanup

- `python3 -m unittest tests/test_validate_results.py -v`: 12 passed.
- `bash tests/test_dockerfile.sh`: passed.
- `bash tests/test_build_scripts.sh`: passed.
- `bash tests/test_lifecycle_scripts.sh`: passed.
- Final Docker build and image inspection: exit 0.
- Validator exits for final probe and small: 0.
- `git diff --check`: passed before implementation commits.
- Exact service and metadata-helper container queries returned empty after final stop.
- Port 30000 had no listener after final stop.

## Nonblocking warnings and follow-up

- Pinned SGLang performs repeated offline checks for optional `hf_quant_config.json` before continuing. These warnings delay startup but do not fail readiness.
- The generic mock uses AIConfigurator's H100 database as specified by the upstream repository fixture. Its output is simulation evidence, not measured H100 or H20 performance.
- A later task should add an optional ShareGPT profile using host-proxy download, fixed URL/size/SHA256, a read-only mount, and explicit `--dataset-path`. It is intentionally outside this random-ids generic smoke.
