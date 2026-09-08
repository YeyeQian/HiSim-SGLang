#!/usr/bin/env bash
set -euo pipefail

root_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
tmp_dir="$(mktemp -d)"
trap 'rm -rf "${tmp_dir}"' EXIT

fake_bin="${tmp_dir}/bin"
mkdir -p "${fake_bin}" "${tmp_dir}/results" "${tmp_dir}/cache"

cat >"${fake_bin}/ss" <<'EOF'
#!/usr/bin/env bash
if [[ "$*" == *'sport = :17897'* ]]; then
  echo 'LISTEN 0 128 127.0.0.1:17897'
elif [[ "${FAKE_PORT_BUSY:-0}" = 1 && "$*" == *"sport = :${HISIM_PORT:-30000}"* ]]; then
  echo 'LISTEN 0 128 127.0.0.1:30000'
fi
EOF

cat >"${fake_bin}/docker" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >>"${FAKE_DOCKER_LOG}"
case "${1:-} ${2:-}" in
  'info --format') echo /tmp ;;
  'container inspect')
    if [[ "${3:-}" = *-metadata ]]; then
      [[ "${FAKE_METADATA_COLLISION:-0}" = 1 ]] || exit 1
    else
      [[ "${FAKE_NAME_EXISTS:-0}" = 1 ]] || exit 1
    fi
    echo '{}'
    ;;
  'run --rm')
    if [[ "${FAKE_METADATA_EXIT:-}" != '' ]]; then
      exit "${FAKE_METADATA_EXIT}"
    fi
    ;;
  'run --detach') echo project-container-id ;;
  'inspect --format')
    if [[ "${4:-}" = *-metadata ]]; then
      [[ "${FAKE_METADATA_EXISTS:-0}" = 1 ]] || exit 1
      if [[ "$3" = *Config.Labels* ]]; then
        echo metadata
      else
        echo metadata-container-id
      fi
      exit 0
    fi
    case "$3" in
      *State.Running*) [[ "${FAKE_CONTAINER_RUNNING:-1}" = 1 ]] && echo true || echo false ;;
      *State.Status*) echo "${FAKE_CONTAINER_STATUS:-running}" ;;
      *State.ExitCode*) echo "${FAKE_CONTAINER_EXIT_CODE:-0}" ;;
      *Id*) echo project-container-id ;;
      *) echo unknown ;;
    esac
    ;;
  'inspect project-container-id') echo '{"Id":"project-container-id","Name":"/hisim-sglang-cpu-smoke"}' ;;
  'logs project-container-id') printf '%s\n' "${FAKE_SERVER_LOGS:-HiSim simulation hook enabled}" ;;
  'logs --follow')
    if [[ -n "${FAKE_FOLLOW_WAIT_FILE:-}" ]]; then
      while [[ ! -s "${FAKE_FOLLOW_WAIT_FILE}" ]]; do sleep 0.01; done
      cat "${FAKE_FOLLOW_WAIT_FILE}"
    else
      printf '%s\n' "${FAKE_SERVER_LOGS:-HiSim simulation hook enabled}"
    fi
    ;;
  'stats --no-stream') echo '12.00%,100MiB / 32GiB,1KiB / 2KiB,3' ;;
  'exec project-container-id')
    if [[ "${FAKE_BENCH_TRIGGER_GUARD:-0}" = 1 ]]; then
      printf '%s\n' 'Load weight end.' >"${FAKE_FOLLOW_WAIT_FILE}"
      sleep 0.1
    fi
    echo benchmark-stdout
    echo benchmark-stderr >&2
    exit "${FAKE_BENCH_EXIT:-0}"
    ;;
  'stop project-container-id'|'rm project-container-id'|'stop metadata-container-id'|'rm metadata-container-id') ;;
  *) ;;
esac
EOF

cat >"${fake_bin}/curl" <<'EOF'
#!/usr/bin/env bash
[[ "${FAKE_CURL_READY:-1}" = 1 ]]
EOF

cat >"${fake_bin}/timeout" <<'EOF'
#!/usr/bin/env bash
duration="$1"
shift
printf '%s\n' "${duration}" >>"${FAKE_TIMEOUT_LOG}"
if [[ "${FAKE_TIMEOUT_EXIT:-}" != '' ]]; then
  exit "${FAKE_TIMEOUT_EXIT}"
fi
exec "$@"
EOF

chmod +x "${fake_bin}"/*

export PATH="${fake_bin}:${PATH}"
export FAKE_DOCKER_LOG="${tmp_dir}/docker.log"
export FAKE_TIMEOUT_LOG="${tmp_dir}/timeout.log"
export RESULTS_ROOT="${tmp_dir}/results"
export HF_CACHE_DIR="${tmp_dir}/cache"
export READINESS_INTERVAL_SECONDS=0

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

assert_contains() {
  local file="$1" expected="$2"
  grep -F -- "${expected}" "${file}" >/dev/null || fail "${file} lacks: ${expected}"
}

assert_not_contains() {
  local file="$1" unexpected="$2"
  if grep -F -- "${unexpected}" "${file}" >/dev/null; then
    fail "${file} unexpectedly contains: ${unexpected}"
  fi
}

for script in start_server.sh wait_ready.sh run_benchmark.sh stop_server.sh; do
  [[ -x "${root_dir}/scripts/${script}" ]] || fail "scripts/${script} must exist and be executable"
done

sharegpt_fixture="${tmp_dir}/sharegpt.json"
printf '[{"conversations":[{"from":"human","value":"hi"},{"from":"gpt","value":"hello"}]}]\n' >"${sharegpt_fixture}"
export SHAREGPT_DATASET="${sharegpt_fixture}"
export SHAREGPT_SIZE="$(stat -c %s "${sharegpt_fixture}")"
export SHAREGPT_SHA256="$(sha256sum "${sharegpt_fixture}" | awk '{print $1}')"

# ShareGPT is opt-in: a normal generic server has no dataset bind, while the
# explicit mode validates and mounts the exact host file read-only.
: >"${FAKE_DOCKER_LOG}"
bash "${root_dir}/scripts/start_server.sh" generic >/dev/null
assert_not_contains "${FAKE_DOCKER_LOG}" '/opt/hisim-data/sharegpt.json'
bash "${root_dir}/scripts/stop_server.sh" >/dev/null

: >"${FAKE_DOCKER_LOG}"
bash "${root_dir}/scripts/start_server.sh" generic sharegpt >/dev/null
assert_contains "${FAKE_DOCKER_LOG}" "${sharegpt_fixture}:/opt/hisim-data/sharegpt.json:ro"
state_dir="${RESULTS_ROOT}/.state/hisim-sglang-cpu-smoke"
test "$(<"${state_dir}/dataset_profile")" = sharegpt
bash "${root_dir}/scripts/stop_server.sh" >/dev/null

printf 'invalid\n' >"${sharegpt_fixture}"
if bash "${root_dir}/scripts/start_server.sh" generic sharegpt >/dev/null 2>&1; then
  fail 'ShareGPT start must reject a missing or invalid verified dataset'
fi
printf '[{"conversations":[{"from":"human","value":"hi"},{"from":"gpt","value":"hello"}]}]\n' >"${sharegpt_fixture}"

if bash "${root_dir}/scripts/start_server.sh" h20 sharegpt >/dev/null 2>&1; then
  fail 'ShareGPT must remain a separate generic workload-shape profile'
fi

: >"${FAKE_DOCKER_LOG}"
bash "${root_dir}/scripts/start_server.sh" generic
assert_contains "${FAKE_DOCKER_LOG}" 'run --rm --name hisim-sglang-cpu-smoke-metadata --network host'
assert_contains "${FAKE_DOCKER_LOG}" '--label com.hisim-sglang.role=metadata'
assert_contains "${FAKE_DOCKER_LOG}" '--env HTTP_PROXY=http://127.0.0.1:17897'
assert_contains "${FAKE_DOCKER_LOG}" '--env HTTPS_PROXY=http://127.0.0.1:17897'
assert_contains "${FAKE_DOCKER_LOG}" 'AutoConfig.from_pretrained'
assert_contains "${FAKE_DOCKER_LOG}" 'AutoTokenizer.from_pretrained'
assert_not_contains "${FAKE_DOCKER_LOG}" 'AutoModel.from_pretrained'
assert_contains "${FAKE_DOCKER_LOG}" 'run --detach'
assert_contains "${FAKE_DOCKER_LOG}" '--cpus 16'
assert_contains "${FAKE_DOCKER_LOG}" '--memory 32g'
assert_contains "${FAKE_DOCKER_LOG}" '--shm-size 4g'
assert_contains "${FAKE_DOCKER_LOG}" '--network bridge'
assert_contains "${FAKE_DOCKER_LOG}" '--publish 127.0.0.1:30000:30000'
assert_contains "${FAKE_DOCKER_LOG}" '--user 10001:10001'
assert_contains "${FAKE_DOCKER_LOG}" 'third_party/tair-kvcache:/workspace/tair-kvcache:ro'
assert_contains "${FAKE_DOCKER_LOG}" 'config.json:/run/hisim/config.json:ro'
assert_contains "${FAKE_DOCKER_LOG}" "${tmp_dir}/cache:/home/app/.cache/huggingface:rw"
assert_contains "${FAKE_DOCKER_LOG}" '--env HF_HUB_OFFLINE=1'
assert_not_contains "${FAKE_DOCKER_LOG}" '--gpus'
assert_contains "${root_dir}/scripts/start_server.sh" ':/opt/hisim-data/aic:ro'

state_dir="${RESULTS_ROOT}/.state/hisim-sglang-cpu-smoke"
[[ -s "${state_dir}/container_id" ]] || fail 'start must save the container id'
run_dir="$(<"${state_dir}/run_dir")"
assert_contains "${FAKE_DOCKER_LOG}" "${run_dir}:/results:rw"
[[ "$(stat -c %a "${tmp_dir}/cache")" = 777 ]] || fail 'cache root must be writable by the fixed non-root image UID'
[[ "$(stat -c %a "${run_dir}")" = 777 ]] || fail 'result root must be writable by the fixed non-root image UID'
[[ -f "${run_dir}/server/generic/launch.env" ]] || fail 'start must save launch metadata'
[[ -f "${run_dir}/server/generic/cache-before.txt" ]] || fail 'start must save cache size'

FAKE_PORT_BUSY=1
export FAKE_PORT_BUSY
if bash "${root_dir}/scripts/start_server.sh" generic >/dev/null 2>&1; then
  fail 'start must reject a busy port'
fi
unset FAKE_PORT_BUSY

FAKE_NAME_EXISTS=1
export FAKE_NAME_EXISTS
if bash "${root_dir}/scripts/start_server.sh" generic >/dev/null 2>&1; then
  fail 'start must reject an exact-name collision'
fi
unset FAKE_NAME_EXISTS

if bash "${root_dir}/scripts/start_server.sh" invalid >/dev/null 2>&1; then
  fail 'start must reject an invalid kind'
fi

# The guard begins with server startup and recognizes the pinned SGLang message.
rm -rf "${state_dir}"
FAKE_SERVER_LOGS='Load weight begin.'
export FAKE_SERVER_LOGS
: >"${FAKE_DOCKER_LOG}"
bash "${root_dir}/scripts/start_server.sh" generic >/dev/null
for _ in $(seq 1 50); do
  grep -F 'stop project-container-id' "${FAKE_DOCKER_LOG}" >/dev/null && break
  sleep 0.02
done
assert_contains "${FAKE_DOCKER_LOG}" 'logs --follow project-container-id'
assert_contains "${FAKE_DOCKER_LOG}" 'stop project-container-id'
assert_contains "${root_dir}/scripts/start_server.sh" 'Load weight end[.]'
unset FAKE_SERVER_LOGS

rm -rf "${state_dir}"
export H20_DATA_DIR="${tmp_dir}/h20-data"
if bash "${root_dir}/scripts/start_server.sh" h20 >/dev/null 2>&1; then
  fail 'h20 start must reject missing Task 8 config/data'
fi

mkdir -p \
  "${H20_DATA_DIR}/data/h20_sxm/sglang/0.5.6.post2" \
  "${H20_DATA_DIR}/xgb_models/qwen3_8B"
printf 'device: h20_sxm\n' >"${H20_DATA_DIR}/h20_sxm.yaml"
printf 'table\n' >"${H20_DATA_DIR}/data/h20_sxm/sglang/0.5.6.post2/gemm_perf.txt"
printf '{}\n' >"${H20_DATA_DIR}/xgb_models/qwen3_8B/model.json"
: >"${FAKE_DOCKER_LOG}"
bash "${root_dir}/scripts/start_server.sh" h20 >/dev/null
assert_contains "${FAKE_DOCKER_LOG}" "${H20_DATA_DIR}:/opt/hisim-data/aic:ro"
bash "${root_dir}/scripts/stop_server.sh" >/dev/null

rm "${H20_DATA_DIR}/xgb_models/qwen3_8B/model.json"
if bash "${root_dir}/scripts/start_server.sh" h20 >/dev/null 2>&1; then
  fail 'h20 start must reject an empty Qwen3-8B XGB directory'
fi
unset H20_DATA_DIR

bash "${root_dir}/scripts/start_server.sh" generic >/dev/null
run_dir="$(<"${state_dir}/run_dir")"
: >"${FAKE_DOCKER_LOG}"
READINESS_TIMEOUT_SECONDS=7 bash "${root_dir}/scripts/wait_ready.sh"
assert_contains "${FAKE_DOCKER_LOG}" 'inspect --format {{.State.Running}} project-container-id'
assert_contains "${tmp_dir}/results/.state/hisim-sglang-cpu-smoke/run_dir" ''
assert_contains "${run_dir}/server/generic/readiness.log" '/health'

for profile in probe small; do
  : >"${FAKE_DOCKER_LOG}"
  : >"${FAKE_TIMEOUT_LOG}"
  BENCHMARK_TIMEOUT_SECONDS=13 bash "${root_dir}/scripts/run_benchmark.sh" generic "${profile}"
  bench_dir="$(<"${state_dir}/last-benchmark-${profile}")"
  [[ "$(stat -c %a "${bench_dir}")" = 777 ]] || fail "${profile} result directory must be container-writable"
  [[ -f "${bench_dir}/exit-code.txt" ]] || fail "${profile} must save exit code"
  [[ -f "${bench_dir}/stdout.log" && -f "${bench_dir}/stderr.log" ]] || fail "${profile} must save output"
  [[ -f "${bench_dir}/docker-stats.csv" && -f "${bench_dir}/resource-peak.txt" ]] || fail "${profile} must save resource evidence"
  [[ -f "${bench_dir}/cache-weight-changes.txt" ]] || fail "${profile} must save the cache weight-file scan"
  [[ -f "${bench_dir}/container-inspect.json" ]] || fail "${profile} must save inspect evidence"
  assert_contains "${FAKE_TIMEOUT_LOG}" 13
  assert_contains "${FAKE_DOCKER_LOG}" 'exec project-container-id /usr/local/bin/entrypoint.sh bench'
  assert_contains "${bench_dir}/command.txt" '--bench-mode simulation'
  assert_contains "${bench_dir}/command.txt" '--warmup-requests 0'
  assert_contains "${bench_dir}/command.txt" '--dataset-name random-ids'
  if [[ "${profile}" = probe ]]; then
    assert_contains "${bench_dir}/command.txt" '--num-prompts 2'
    assert_contains "${bench_dir}/command.txt" '--max-concurrency 2'
  else
    assert_contains "${bench_dir}/command.txt" '--num-prompts 16'
    assert_contains "${bench_dir}/command.txt" '--max-concurrency 16'
    assert_contains "${bench_dir}/command.txt" '--random-input-len 256'
    assert_contains "${bench_dir}/command.txt" '--random-output-len 32'
  fi
done

first_probe_dir="$(<"${state_dir}/last-benchmark-probe")"
# A ShareGPT benchmark requires a fresh server explicitly started with the
# verified mount, and uses the real second turn as the output-length source.
bash "${root_dir}/scripts/stop_server.sh" >/dev/null
bash "${root_dir}/scripts/start_server.sh" generic >/dev/null
if bash "${root_dir}/scripts/run_benchmark.sh" generic sharegpt >/dev/null 2>&1; then
  fail 'ShareGPT benchmark must reject a server without the verified mount'
fi
bash "${root_dir}/scripts/stop_server.sh" >/dev/null
bash "${root_dir}/scripts/start_server.sh" generic sharegpt >/dev/null
: >"${FAKE_DOCKER_LOG}"
BENCHMARK_TIMEOUT_SECONDS=13 bash "${root_dir}/scripts/run_benchmark.sh" generic sharegpt
bench_dir="$(<"${state_dir}/last-benchmark-sharegpt")"
assert_contains "${bench_dir}/command.txt" '--dataset-name sharegpt'
assert_contains "${bench_dir}/command.txt" '--dataset-path /opt/hisim-data/sharegpt.json'
assert_contains "${bench_dir}/command.txt" '--num-prompts 16'
assert_contains "${bench_dir}/command.txt" '--max-concurrency 16'
assert_contains "${bench_dir}/command.txt" '--seed 1'
assert_contains "${bench_dir}/command.txt" '--sharegpt-context-len 4096'
assert_not_contains "${bench_dir}/command.txt" '--sharegpt-output-len'
bash "${root_dir}/scripts/stop_server.sh" >/dev/null
bash "${root_dir}/scripts/start_server.sh" generic >/dev/null

BENCHMARK_TIMEOUT_SECONDS=13 bash "${root_dir}/scripts/run_benchmark.sh" generic probe >/dev/null
second_probe_dir="$(<"${state_dir}/last-benchmark-probe")"
[[ "${first_probe_dir}" != "${second_probe_dir}" ]] || fail 'benchmark invocations must use unique evidence directories'
[[ -f "${first_probe_dir}/exit-code.txt" && -f "${second_probe_dir}/exit-code.txt" ]] || fail 'unique benchmark evidence was overwritten'

if RESOURCE_SAMPLE_INTERVAL_SECONDS=0 bash "${root_dir}/scripts/run_benchmark.sh" generic probe >/dev/null 2>&1; then
  fail 'zero resource sampling interval must be rejected'
fi

FAKE_BENCH_EXIT=23
export FAKE_BENCH_EXIT
if bash "${root_dir}/scripts/run_benchmark.sh" generic probe >/dev/null 2>&1; then
  fail 'benchmark must preserve a nonzero exit status'
fi
bench_dir="$(<"${state_dir}/last-benchmark-probe")"
[[ "$(<"${bench_dir}/exit-code.txt")" = 23 ]] || fail 'saved benchmark exit status is wrong'
unset FAKE_BENCH_EXIT

# Keep the log follower alive and trigger the pinned guard while docker exec is
# in flight, proving protection continues through benchmark execution.
bash "${root_dir}/scripts/stop_server.sh" >/dev/null
export FAKE_FOLLOW_WAIT_FILE="${tmp_dir}/benchmark-guard.trigger"
export FAKE_BENCH_TRIGGER_GUARD=1
: >"${FAKE_DOCKER_LOG}"
bash "${root_dir}/scripts/start_server.sh" generic >/dev/null
run_dir="$(<"${state_dir}/run_dir")"
: >"${FAKE_DOCKER_LOG}"
if bash "${root_dir}/scripts/run_benchmark.sh" generic probe >/dev/null 2>&1; then
  fail 'continuous weight loading guard must fail the in-flight benchmark'
fi
bench_dir="$(find "${run_dir}/benchmark/generic/probe" -mindepth 1 -maxdepth 1 -type d | sort | tail -1)"
assert_contains "${bench_dir}/guard-failure.txt" 'Load weight end.'
assert_contains "${FAKE_DOCKER_LOG}" 'stop project-container-id'
assert_contains "${FAKE_DOCKER_LOG}" 'rm project-container-id'
unset FAKE_FOLLOW_WAIT_FILE FAKE_BENCH_TRIGGER_GUARD

# Recreate state to exercise the independent real-forward guard.
bash "${root_dir}/scripts/start_server.sh" generic >/dev/null
run_dir="$(<"${state_dir}/run_dir")"
FAKE_SERVER_LOGS='ModelRunner.forward started'
export FAKE_SERVER_LOGS
if bash "${root_dir}/scripts/run_benchmark.sh" generic probe >/dev/null 2>&1; then
  fail 'real-forward guard must fail the benchmark'
fi
bench_dir="$(find "${run_dir}/benchmark/generic/probe" -mindepth 1 -maxdepth 1 -type d | sort | tail -1)"
assert_contains "${bench_dir}/guard-failure.txt" 'ModelRunner.forward'
unset FAKE_SERVER_LOGS

# An importable NVIDIA telemetry package is allowed, but CUDA initialization is not.
bash "${root_dir}/scripts/start_server.sh" generic >/dev/null
run_dir="$(<"${state_dir}/run_dir")"
FAKE_SERVER_LOGS='Initializing CUDA runtime'
export FAKE_SERVER_LOGS
if bash "${root_dir}/scripts/run_benchmark.sh" generic probe >/dev/null 2>&1; then
  fail 'CUDA initialization guard must fail the benchmark'
fi
bench_dir="$(find "${run_dir}/benchmark/generic/probe" -mindepth 1 -maxdepth 1 -type d | sort | tail -1)"
assert_contains "${bench_dir}/guard-failure.txt" 'Initializing CUDA'
unset FAKE_SERVER_LOGS

# A readiness timeout is bounded and cleans up only the recorded container.
bash "${root_dir}/scripts/start_server.sh" generic >/dev/null
FAKE_CURL_READY=0
export FAKE_CURL_READY
: >"${FAKE_DOCKER_LOG}"
if READINESS_TIMEOUT_SECONDS=0 bash "${root_dir}/scripts/wait_ready.sh" >/dev/null 2>&1; then
  fail 'readiness timeout must fail'
fi
assert_contains "${FAKE_DOCKER_LOG}" 'stop project-container-id'
assert_contains "${FAKE_DOCKER_LOG}" 'rm project-container-id'
unset FAKE_CURL_READY

# Recreate state to exercise early-exit cleanup and exact-ID removal.
bash "${root_dir}/scripts/start_server.sh" generic >/dev/null
FAKE_CONTAINER_RUNNING=0
FAKE_CONTAINER_STATUS=exited
export FAKE_CONTAINER_RUNNING FAKE_CONTAINER_STATUS
: >"${FAKE_DOCKER_LOG}"
if bash "${root_dir}/scripts/wait_ready.sh" >/dev/null 2>&1; then
  fail 'readiness must fail immediately after an early container exit'
fi
assert_contains "${FAKE_DOCKER_LOG}" 'logs project-container-id'
assert_contains "${FAKE_DOCKER_LOG}" 'rm project-container-id'
unset FAKE_CONTAINER_RUNNING FAKE_CONTAINER_STATUS

# Idempotent when no state exists; never use filters, globs, or broad cleanup.
: >"${FAKE_DOCKER_LOG}"
bash "${root_dir}/scripts/stop_server.sh"
assert_not_contains "${FAKE_DOCKER_LOG}" 'prune'
assert_not_contains "${FAKE_DOCKER_LOG}" 'container ls'
assert_not_contains "${FAKE_DOCKER_LOG}" '--filter'

bash "${root_dir}/scripts/start_server.sh" generic >/dev/null
: >"${FAKE_DOCKER_LOG}"
bash "${root_dir}/scripts/stop_server.sh"
assert_contains "${FAKE_DOCKER_LOG}" 'inspect --format {{.Id}} hisim-sglang-cpu-smoke'
assert_contains "${FAKE_DOCKER_LOG}" 'stop project-container-id'
assert_contains "${FAKE_DOCKER_LOG}" 'rm project-container-id'
assert_not_contains "${FAKE_DOCKER_LOG}" 'rm hisim-sglang-cpu-smoke'

# A failed/timed-out metadata helper is removed only after its ownership label
# and full ID are checked. It must never leave normal service state behind.
FAKE_METADATA_EXIT=124
FAKE_METADATA_EXISTS=1
export FAKE_METADATA_EXIT FAKE_METADATA_EXISTS
: >"${FAKE_DOCKER_LOG}"
if bash "${root_dir}/scripts/start_server.sh" generic >/dev/null 2>&1; then
  fail 'metadata preparation timeout must fail startup'
fi
assert_contains "${FAKE_DOCKER_LOG}" 'inspect --format {{index .Config.Labels "com.hisim-sglang.role"}} hisim-sglang-cpu-smoke-metadata'
assert_contains "${FAKE_DOCKER_LOG}" 'inspect --format {{.Id}} hisim-sglang-cpu-smoke-metadata'
assert_contains "${FAKE_DOCKER_LOG}" 'stop metadata-container-id'
assert_contains "${FAKE_DOCKER_LOG}" 'rm metadata-container-id'
[[ ! -s "${state_dir}/container_id" ]] || fail 'metadata failure must not create service state'
unset FAKE_METADATA_EXIT FAKE_METADATA_EXISTS

# Proxy overrides must never appear in durable command evidence (including any
# future credential-bearing form accepted by proxy validation).
export DOCKER_PROJECT_PROXY='http://private-proxy.example:17897'
bash "${root_dir}/scripts/start_server.sh" generic >/dev/null
run_dir="$(<"${state_dir}/run_dir")"
assert_not_contains "${run_dir}/server/generic/metadata-command.txt" 'private-proxy.example'
assert_contains "${run_dir}/server/generic/metadata-command.txt" 'HTTP_PROXY=<redacted>'
bash "${root_dir}/scripts/stop_server.sh" >/dev/null
unset DOCKER_PROJECT_PROXY

printf 'lifecycle script tests passed\n'
