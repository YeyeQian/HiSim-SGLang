#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "${script_dir}/lib/common.sh"

kind="${1:-}"
profile="${2:-}"
[[ $# -eq 2 && ( "${kind}" = generic || "${kind}" = h20 ) ]] ||
  die "usage: $0 generic|h20 probe|small|sharegpt"
[[ "${profile}" = probe || "${profile}" = small || ( "${kind}" = generic && "${profile}" = sharegpt ) ]] ||
  die "usage: $0 generic|h20 probe|small|sharegpt"

repo_root="$(project_root)"
container_name="${HISIM_CONTAINER_NAME:-hisim-sglang-cpu-smoke}"
results_root="${RESULTS_ROOT:-${repo_root}/results}"
cache_dir="${HF_CACHE_DIR:-${repo_root}/cache/huggingface}"
state_dir="${results_root}/.state/${container_name}"
timeout_seconds="${BENCHMARK_TIMEOUT_SECONDS:-300}"
stats_interval="${RESOURCE_SAMPLE_INTERVAL_SECONDS:-1}"
[[ "${timeout_seconds}" =~ ^[1-9][0-9]*$ && "${stats_interval}" =~ ^[0-9]+([.][0-9]+)?$ ]] &&
  awk -v interval="${stats_interval}" 'BEGIN { exit !(interval > 0) }' ||
  die "benchmark timeout and resource sampling interval must be positive"
[[ -s "${state_dir}/container_id" && -s "${state_dir}/run_dir" && -s "${state_dir}/kind" ]] ||
  die "no active project container state exists at ${state_dir}"
require_command docker
require_command timeout

container_id="$(<"${state_dir}/container_id")"
run_dir="$(<"${state_dir}/run_dir")"
active_kind="$(<"${state_dir}/kind")"
[[ "${active_kind}" = "${kind}" ]] || die "active container kind is ${active_kind}, not ${kind}"
active_dataset_profile=none
if [[ -s "${state_dir}/dataset_profile" ]]; then
  active_dataset_profile="$(<"${state_dir}/dataset_profile")"
fi
sharegpt_bound=0
sampler_pid=""
cleanup_failed_sharegpt_attempt() {
  local status=$?
  trap - EXIT INT TERM
  if [[ -n "${sampler_pid}" ]]; then
    kill "${sampler_pid}" >/dev/null 2>&1 || true
    wait "${sampler_pid}" 2>/dev/null || true
  fi
  if [[ "${sharegpt_bound}" -eq 1 && "${status}" -ne 0 ]]; then
    bash "${repo_root}/scripts/stop_server.sh" >/dev/null 2>&1 || true
  fi
  exit "${status}"
}
if [[ "${active_dataset_profile}" = sharegpt ]]; then
  sharegpt_bound=1
  trap cleanup_failed_sharegpt_attempt EXIT
  trap 'exit 130' INT
  trap 'exit 143' TERM
  [[ "${profile}" = sharegpt ]] ||
    die "ShareGPT-bound container accepts only the sharegpt profile; start a fresh generic container for probe or small"
  if ! (
    set -o noclobber
    printf '%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" >"${state_dir}/sharegpt-attempted"
  ) 2>/dev/null; then
    die "ShareGPT benchmark was already attempted; start a fresh generic sharegpt container"
  fi
elif [[ "${profile}" = sharegpt ]]; then
  [[ -s "${state_dir}/dataset_profile" ]] &&
    [[ "$(<"${state_dir}/dataset_profile")" = sharegpt ]] ||
    die "active container lacks the verified ShareGPT mount; stop it and run scripts/start_server.sh generic sharegpt"
fi
invocation_id="$(date -u +%Y%m%dT%H%M%S%N)-$$"
bench_dir="${run_dir}/benchmark/${kind}/${profile}/${invocation_id}"
server_dir="${run_dir}/server/${kind}"
mkdir -p "${bench_dir}" "${cache_dir}"
chmod 0777 "${bench_dir}"
printf '%s\n' "${bench_dir}" >"${state_dir}/last-benchmark-${profile}"
guard_failure="${server_dir}/runtime-guard-failure.txt"
if [[ -s "${guard_failure}" ]]; then
  cp "${guard_failure}" "${bench_dir}/guard-failure.txt"
  bash "${repo_root}/scripts/stop_server.sh" >/dev/null 2>&1 || true
  exit 90
fi

common_args=(
  --backend sglang
  --base-url http://127.0.0.1:30000
  --model Qwen/Qwen3-8B
  --bench-mode simulation
  --warmup-requests 0
  --disable-tqdm
  --output-file "/results/benchmark/${kind}/${profile}/${invocation_id}/metrics.json"
)
case "${profile}" in
  probe)
    profile_args=(--dataset-name random-ids --num-prompts 2 --max-concurrency 2 --random-input-len 16 --random-output-len 8)
    ;;
  small)
    profile_args=(--dataset-name random-ids --num-prompts 16 --max-concurrency 16 --random-input-len 256 --random-output-len 32)
    ;;
  sharegpt)
    profile_args=(--dataset-name sharegpt --dataset-path /opt/hisim-data/sharegpt.json --num-prompts 16 --max-concurrency 16 --seed 1 --sharegpt-context-len 4096)
    ;;
esac
command=(docker exec "${container_id}" /usr/local/bin/entrypoint.sh bench "${common_args[@]}" "${profile_args[@]}")

printf '%q ' timeout "${timeout_seconds}s" "${command[@]}" >"${bench_dir}/command.txt"
printf '\n' >>"${bench_dir}/command.txt"
printf '%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" >"${bench_dir}/started-at.txt"
du -sk -- "${cache_dir}" >"${bench_dir}/cache-before.txt"
touch "${bench_dir}/benchmark-start.marker"
docker inspect "${container_id}" >"${bench_dir}/container-inspect.json" 2>&1 || true
printf 'timestamp,cpu,memory,net_io,pids\n' >"${bench_dir}/docker-stats.csv"

sample_once() {
  local sample
  sample="$(docker stats --no-stream --format '{{.CPUPerc}},{{.MemUsage}},{{.NetIO}},{{.PIDs}}' "${container_id}" 2>/dev/null || true)"
  if [[ -n "${sample}" ]]; then
    printf '%s,%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "${sample}" >>"${bench_dir}/docker-stats.csv"
  fi
}

sample_resources() {
  while :; do
    sample_once
    sleep "${stats_interval}"
  done
}
sample_once
sample_resources &
sampler_pid=$!

set +e
timeout "${timeout_seconds}s" "${command[@]}" >"${bench_dir}/stdout.log" 2>"${bench_dir}/stderr.log"
benchmark_status=$?
set -e
kill "${sampler_pid}" >/dev/null 2>&1 || true
wait "${sampler_pid}" 2>/dev/null || true
sampler_pid=""

printf '%s\n' "${benchmark_status}" >"${bench_dir}/exit-code.txt"
printf '%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" >"${bench_dir}/ended-at.txt"
du -sk -- "${cache_dir}" >"${bench_dir}/cache-after.txt"
find "${cache_dir}" -type f \
  \( -name '*.safetensors' -o -name 'pytorch_model*.bin' -o -name '*.gguf' \) \
  -newer "${bench_dir}/benchmark-start.marker" -print >"${bench_dir}/cache-weight-changes.txt"
docker inspect "${container_id}" >"${bench_dir}/container-inspect-after.json" 2>&1 || true
docker logs "${container_id}" >"${server_dir}/container.log" 2>&1 || true

awk -F, '
  function mib(value, number) {
    sub(/^[[:space:]]*/, "", value)
    number=value + 0
    if (value ~ /GiB/) return number * 1024
    if (value ~ /KiB/) return number / 1024
    if (value ~ /B/) return number / 1024 / 1024
    return number
  }
  NR > 1 {
    cpu=$2; gsub(/%/, "", cpu); if (cpu + 0 > peak_cpu) peak_cpu=cpu + 0
    split($3, usage, "/"); memory_mib=mib(usage[1]); if (memory_mib > peak_memory_mib) peak_memory_mib=memory_mib
  }
  END { printf "peak_cpu_percent=%.2f\npeak_memory_mib=%.2f\n", peak_cpu, peak_memory_mib }
' "${bench_dir}/docker-stats.csv" >"${bench_dir}/resource-peak.txt"

guard_pattern='Load weight begin[.]|Load weight end[.]|Loading checkpoint shards|Loading safetensors checkpoint|Loading model weights|Weights loaded into memory|Executing real model forward|ModelRunner[.]forward|Forward pass started|CUDA (runtime )?initialized|Initializing CUDA|torch[.]cuda[.]init|NCCL communicator'
guard_match="$(grep -E -m1 "${guard_pattern}" "${server_dir}/container.log" || true)"
if [[ -s "${guard_failure}" || -n "${guard_match}" ]]; then
  if [[ -s "${guard_failure}" ]]; then
    cp "${guard_failure}" "${bench_dir}/guard-failure.txt"
  else
    printf 'Forbidden runtime indicator: %s\n' "${guard_match}" >"${bench_dir}/guard-failure.txt"
  fi
  bash "${repo_root}/scripts/stop_server.sh" || true
  exit 90
fi

exit "${benchmark_status}"
