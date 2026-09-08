# Optional ShareGPT Host Dataset and Workload Report

## Status and classification

`DONE`

The optional ShareGPT workload completed the CPU-only HiSim → SGLang HTTP → benchmark path with 16 successful and zero failed requests. Its exact classification is `sharegpt_workload_shape` with calibration label `WORKLOAD_SHAPE_ONLY`. It exercises realistic conversational text and length distributions; it is not answer-quality evaluation, measured hardware performance, independent predictor calibration, or capacity-planning evidence. The required `random-ids` probe/small smoke profiles remain unchanged and independent of this dataset.

## Implementation commit

- `f8ea450` — `feat: add optional ShareGPT workload profile`
- `10b0d2c` — `fix: enforce fresh ShareGPT benchmark lifecycle`
- `0e41715` — `fix: clean up early ShareGPT benchmark failures`

The implementation adds a proxy-aware verified host downloader, immutable provenance, explicit opt-in lifecycle handling, an exact read-only file bind, pinned benchmark arguments, and a dedicated validator classification. A normal `scripts/start_server.sh generic` invocation does not mount or require ShareGPT. The dataset is mounted only by `scripts/start_server.sh generic sharegpt`, and the profile runs only through `scripts/run_benchmark.sh generic sharegpt`.

## TDD and static verification evidence

- Initial red evidence: `logs/sharegpt/downloader-red.*`, `lifecycle-red.*`, and `validator-red.*` failed because the downloader, optional lifecycle mode, and profile semantics did not exist.
- Compatibility red/green: the host has curl 7.29.0, which does not implement `--retry-all-errors`; `downloader-green.*` preserved that first error. The final implementation uses supported `--retry 2`, `--retry-delay 2`, and `--retry-max-time 5400` flags with 10-second connect and 1800-second transfer limits.
- Stale partial red/green: `stale-partial-red.*` proved a valid cached file initially left a stale `.partial`; the final code removes the partial before revalidating the final file.
- Final focused verification: `logs/sharegpt/static-focused-final.*` covers downloader outcomes, lifecycle behavior, validator semantics, pins, Bash/Python syntax, and `git diff --check`.
- Review-fix red/green: `logs/sharegpt/review-fix-red.*` first exposed incomplete normal-stop cleanup; `review-fix-cleanup-green.*` then progressed to the wrong-profile acceptance failure. `review-fix-no-id-red.*` reproduced the stale ShareGPT-only state. `review-fix-all-green.*` proves full state cleanup and the fresh-server attempt rules.
- Early-error red/green: `logs/sharegpt/review-fix-early-error-red.*` reproduced a ShareGPT service left reusable after invalid benchmark settings; `review-fix-early-error-green.*` proves cleanup after state selection but before benchmark execution.

The downloader tests use only small local fixtures. They cover exact size/SHA validation, atomic rename, verified cache reuse, stale partial cleanup, failed-transfer partial cleanup, preservation of an existing invalid final file until a verified replacement exists, proxy forwarding, finite timeout/retry flags, and unchanged TLS verification.

## Dataset provenance and retained asset

- URL: `https://huggingface.co/datasets/anon8231489123/ShareGPT_Vicuna_unfiltered/resolve/main/ShareGPT_V3_unfiltered_cleaned_split.json`
- Observed Hugging Face dataset revision: `192ab2185289094fc556ec8ce5ce1e8e587154ca`
- Exact expected and observed size: `672837942` bytes (641.67 MiB)
- File/LFS object SHA256: `35f0e213ce091ed9b9af2a1f0755e9d39f9ccec34ab281cd4ca60d70f6479ba4`
- Retained host path: `artifacts/downloads/ShareGPT_V3_unfiltered_cleaned_split.json`
- Container path: `/opt/hisim-data/sharegpt.json` (read-only)

The URL contains mutable `main`, so both size and actual file SHA256 are mandatory fail-closed checks. The distinct Xet ETag/hash beginning `d709...` was not used as the file SHA256. The first proxy-backed download completed in 3 minutes 14.66 seconds with exit 0; independent `stat` and `sha256sum` evidence is in `logs/sharegpt/dataset.stat.txt` and `dataset.sha256.txt`. A second downloader invocation revalidated and reused the complete local file without another transfer.

## Live ShareGPT workload result

- Fresh run: `/data/userhome/zhaoyifan/Work/HiSim-SGLang/.worktrees/cpu-docker-smoke/results/20260908T143438Z-generic-29090`
- Benchmark: `/data/userhome/zhaoyifan/Work/HiSim-SGLang/.worktrees/cpu-docker-smoke/results/20260908T143438Z-generic-29090/benchmark/generic/sharegpt/20260908T143714591616333-33879`
- benchmark / validator / stop: `0 / 0 / 0`
- sampled requests: `16`; completed / failed: `16 / 0`
- sampled input / output tokens: `7661 / 3666`
- simulation duration: `3.8249078711680498 s`; wrapper elapsed time: `55.47 s`
- request throughput: `4.183107290140801 requests/s`
- TTFT / TPOT / ITL: `197.7838956876568 / 6.956125939562992 / 6.937133622501331 ms`
- validation: `PASS`, `sharegpt_workload_shape`, `WORKLOAD_SHAPE_ONLY`

The saved benchmark command uses `--dataset-name sharegpt`, the exact container dataset path, 16 prompts, concurrency 16, seed 1, and context length 4096. It deliberately omits `--sharegpt-output-len`; the real second conversation turn supplied the output-length distribution. The benchmark was run against a separate fresh generic server, preserving the offline HiSim request-barrier requirement.

## Runtime guards, resources, and cleanup

Docker inspect recorded the exact host file mounted at `/opt/hisim-data/sharegpt.json` with `RW=false`, bridge networking, loopback-only `127.0.0.1:30000`, 16 CPUs, 32 GiB memory, and 4 GiB shared memory. Peak sampled memory was 5056.51 MiB. Sampled CPU peak remained 0% because the simulation interval completed between samples, so this run supports no CPU-utilization conclusion.

The benchmark cache weight-change file and forbidden-runtime scan are empty. No real model weight load, model forward, CUDA initialization, or NCCL communicator initialization was observed. The initial stop removed the exact service container and metadata helper and freed port 30000, but it incorrectly left `dataset_profile` and `last-benchmark-sharegpt` in the active-state directory; therefore the report's original claim that project state was cleared was inaccurate. Independent review exposed those two files. Commit `10b0d2c` makes all stop branches remove the complete known state set fail-closed, and `logs/sharegpt/review-fix-live-stale-cleanup.log` records cleanup of the actual old residue. The service container, metadata helper, active-state directory, and port listener are now all absent. The image, caches, logs, results, and verified dataset remain available for reuse.

A `generic sharegpt` server now accepts only one ShareGPT benchmark attempt. An atomic noclobber sentinel is installed before any benchmark Docker invocation; probe/small misuse, a repeat, a nonzero benchmark, a timeout, a signal, invalid benchmark settings, or another early error triggers exact project-container cleanup. A successful first attempt leaves the server available only for validation and explicit stop. Fixture tests cover wrong-profile-first, repeat rejection, sentinel ordering, exit 23, timeout 124, invalid pre-execution settings, the normal and already-missing container cleanup branches, and healing the exact no-container-ID residue found in the live state.

Startup logs contain bounded offline Hugging Face checks for optional `hf_quant_config.json`, as in the prior generic runs; they fall through to the cached public model metadata and do not load weights. This ShareGPT result reflects the upstream generic H100-backed mock predictor plus a more realistic workload shape. It must not be interpreted as H20 performance or as a semantic evaluation of generated answers.

`logs/sharegpt/final-verification.*` records a clean image inspection, every `tests/test_*.sh` script, 19 Python tests, Bash/Python syntax checks, and complete-range/current-tree `git diff --check`. Image inspection again reports SGLang `0.5.6.post2`, CPU PyTorch, `torch.cuda.is_available(): False`, no `/dev/nvidia*`, no forbidden accelerator distributions, the pinned AIConfigurator commit, and materialized performance data.

After the review fixes, `logs/sharegpt/review-fix-post-early-final.*` records exit 0 for every shell test, all 19 Python tests, syntax checks, complete-range/current-tree `git diff --check`, absent live containers/state, and a free port 30000.
