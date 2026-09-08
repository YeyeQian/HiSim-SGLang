# Task 8 Report: Pinned H20 Data-path Smoke

## Status and classification

`DONE`

The pinned official H20 data path completed both CPU-only HiSim → SGLang HTTP → benchmark profiles. The exact result classification is `official_h20_data_path` with calibration label `INTEGRATION_ONLY`. This proves data-path integration only; it is not measured H20 hardware performance, independent predictor calibration, or capacity-planning evidence.

## Implementation commit

- `406d1e3` — `feat: add pinned H20 data-path simulation`

The implementation adds the structurally pinned H20 config, complete asset validation, finite three-attempt downloads with per-attempt timeouts, an independent launch-time data gate, and exact H20 result labeling. Existing SGLang, HiSim, AIConfigurator, Qwen3-8B, CPU-only, resource, network, and runtime-guard contracts remain unchanged.

## TDD evidence

- Config contract: `logs/task8/h20-config-tdd-red.*` (missing config, nonzero), then `h20-config-tdd-green.*` (exit 0).
- Asset completeness/size: `logs/task8/h20-fetch-completeness-tdd-red.*` rejected a marker-blessed missing XGB asset, then `h20-fetch-completeness-tdd-green.*` passed.
- Bounded network behavior: `logs/task8/h20-fetch-network-tdd-red.*` exposed one unbounded transfer attempt, then `h20-fetch-network-tdd-green.*` proved exactly three attempts with 10-second connect and 60-second total per-attempt limits.
- Independent launch gate: `logs/task8/h20-start-gate-tdd-red.*` showed the H20 override was ignored, then `h20-start-gate-tdd-green.*` proved missing/empty required data is rejected and the validated root is mounted read-only.
- Result semantics: `logs/task8/h20-validator-tdd-red.*` rejected the new kind before implementation, then `h20-validator-tdd-green.*` passed 15 cases while rejecting generic/H20 cross-labeling and calibration claims.

## Asset provenance

- URL: `https://raw.githubusercontent.com/kunluninsight/LatencyPrism/d242ca5b8d7217e1d235d2fb225ff4a8ba24995a/Hisim/Data/H20_AIC.zip`
- LatencyPrism revision: `d242ca5b8d7217e1d235d2fb225ff4a8ba24995a`
- Size: `9039139` bytes (expected and observed)
- SHA256: `7702dbffe750a9d0f6b7ce547056bfbaa3da5e158ac7fa25e75b057df4792289`
- Preserved archive: `artifacts/downloads/H20_AIC.zip`
- Preserved extracted root: `artifacts/h20_aic/aic/`

The first proxy-backed data preparation succeeded. The hardened downloader then accepted the retained archive only after independently finding a nonempty `h20_sxm.yaml`, `data/h20_sxm/sglang/0.5.6.post2/*.txt`, and `xgb_models/qwen3_8B/*.json`, plus matching size and SHA256. Evidence: `logs/task8/precommit-verification.*` and `live-evidence-audit.log`.

## Live attempts and normalized results

### Probe: fresh container

- Run: `/data/userhome/zhaoyifan/Work/HiSim-SGLang/.worktrees/cpu-docker-smoke/results/20260908T134826Z-h20-79823`
- Benchmark: `/data/userhome/zhaoyifan/Work/HiSim-SGLang/.worktrees/cpu-docker-smoke/results/20260908T134826Z-h20-79823/benchmark/h20/probe/20260908T135408693279063-32798`
- start / readiness / benchmark / validator / stop: `0 / 0 / 0 / 0 / 0`
- completed / failed: `2 / 0`
- duration: `0.03368946022790456 s`; throughput: `59.36574781757486 requests/s`
- TTFT / TPOT / ITL: `7.332915028037409 / 6.589136299966788 / 6.589136299966788 ms`
- validation: `PASS`, `official_h20_data_path`, `INTEGRATION_ONLY`

### Small: separate fresh container

- Run: `/data/userhome/zhaoyifan/Work/HiSim-SGLang/.worktrees/cpu-docker-smoke/results/20260908T135531Z-h20-74386`
- Benchmark: `/data/userhome/zhaoyifan/Work/HiSim-SGLang/.worktrees/cpu-docker-smoke/results/20260908T135531Z-h20-74386/benchmark/h20/small/20260908T135729722395285-77482`
- start / readiness / benchmark / validator / stop: `0 / 0 / 0 / 0 / 0`
- completed / failed: `16 / 0`
- duration: `0.5184791488903842 s`; throughput: `30.859485929650546 requests/s`
- TTFT / TPOT / ITL: `288.8259986451162 / 7.696593550943739 / 7.692411197845389 ms`
- validation: `PASS`, `official_h20_data_path`, `INTEGRATION_ONLY`

Both profiles retained `random-ids`; ShareGPT preparation is intentionally outside Task 8.

## Runtime, cache, resources, and cleanup

Both final logs contain the HiSim config/hook markers, `loading system='h20_sxm', backend='sglang', version='0.5.6.post2'`, Qwen3-8B XGBoost bucket loads from `/opt/hisim-data/aic`, the request barrier marker, and simulation result completion. The forbidden runtime scan found no weight load, real model forward, CUDA initialization, or NCCL communicator initialization. No runtime guard failure file exists and both cache weight-change files are empty.

Docker inspect evidence for both runs records bridge networking, 16 CPUs, 32 GiB memory, 4 GiB shared memory, `127.0.0.1:30000`, and a read-only `/opt/hisim-data/aic` mount. Peak sampled memory was 4211.71 MiB (probe) and 4224.00 MiB (small). The sub-second benchmark intervals completed before the next resource sample, so sampled CPU peak remained 0%; this does not support a CPU-utilization conclusion.

Both exact service containers and metadata helpers are absent, project state is cleared, and port 30000 is free. The image, cache, logs, results, archive, and extracted H20 assets are preserved.

## Final verification and concerns

`logs/task8/final-verification.*` records exit 0 for image inspection, 16 Python tests, every `tests/test_*.sh` script, Bash/Python syntax checks, and `git diff --check 2be872b..406d1e3`. Image inspection reports SGLang `0.5.6.post2`, `torch.cuda.is_available(): False`, no `/dev/nvidia*`, no forbidden accelerator distributions, pinned AIConfigurator, and materialized performance data.

The official archive does not contain optional custom-allreduce, NCCL 2.27.3, or wideep-deepep tables requested by AIConfigurator, so startup logs warnings for those paths. With the pinned `tp_size=1` Qwen3-8B profiles, the available H20 SGLang tables and XGBoost models loaded and both simulations completed. No fallback data was substituted. This remains an integration-only result.
