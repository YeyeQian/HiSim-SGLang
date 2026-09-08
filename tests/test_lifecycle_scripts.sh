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
    [[ "${FAKE_NAME_EXISTS:-0}" = 1 ]] || exit 1
    echo '{}'
    ;;
  'run --detach') echo project-container-id ;;
  'inspect --format')
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
  'stats --no-stream') echo '12.00%,100MiB / 32GiB,1KiB / 2KiB,3' ;;
  'exec project-container-id')
    echo benchmark-stdout
    echo benchmark-stderr >&2
    exit "${FAKE_BENCH_EXIT:-0}"
    ;;
  'stop project-container-id'|'rm project-container-id') ;;
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

: >"${FAKE_DOCKER_LOG}"
bash "${root_dir}/scripts/start_server.sh" generic
assert_contains "${FAKE_DOCKER_LOG}" 'run --detach'
assert_contains "${FAKE_DOCKER_LOG}" '--cpus 16'
assert_contains "${FAKE_DOCKER_LOG}" '--memory 32g'
assert_contains "${FAKE_DOCKER_LOG}" '--shm-size 4g'
assert_contains "${FAKE_DOCKER_LOG}" '--network bridge'
assert_contains "${FAKE_DOCKER_LOG}" '--publish 127.0.0.1:30000:30000'
assert_contains "${FAKE_DOCKER_LOG}" 'third_party/tair-kvcache:/workspace/tair-kvcache:ro'
assert_contains "${FAKE_DOCKER_LOG}" 'config.json:/run/hisim/config.json:ro'
assert_contains "${FAKE_DOCKER_LOG}" "${tmp_dir}/cache:/root/.cache/huggingface:rw"
assert_not_contains "${FAKE_DOCKER_LOG}" '--network host'
assert_not_contains "${FAKE_DOCKER_LOG}" '--gpus'
assert_contains "${root_dir}/scripts/start_server.sh" ':/run/hisim/h20:ro'

state_dir="${RESULTS_ROOT}/.state/hisim-sglang-cpu-smoke"
[[ -s "${state_dir}/container_id" ]] || fail 'start must save the container id'
run_dir="$(<"${state_dir}/run_dir")"
assert_contains "${FAKE_DOCKER_LOG}" "${run_dir}:/results:rw"
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

rm -rf "${state_dir}"
if bash "${root_dir}/scripts/start_server.sh" h20 >/dev/null 2>&1; then
  fail 'h20 start must reject missing Task 8 config/data'
fi

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
  bench_dir="${run_dir}/benchmark/generic/${profile}"
  [[ -f "${bench_dir}/exit-code.txt" ]] || fail "${profile} must save exit code"
  [[ -f "${bench_dir}/stdout.log" && -f "${bench_dir}/stderr.log" ]] || fail "${profile} must save output"
  [[ -f "${bench_dir}/docker-stats.csv" && -f "${bench_dir}/resource-peak.txt" ]] || fail "${profile} must save resource evidence"
  [[ -f "${bench_dir}/cache-weight-changes.txt" ]] || fail "${profile} must save the cache weight-file scan"
  [[ -f "${bench_dir}/container-inspect.json" ]] || fail "${profile} must save inspect evidence"
  assert_contains "${FAKE_TIMEOUT_LOG}" 13
  assert_contains "${FAKE_DOCKER_LOG}" 'exec project-container-id /opt/hisim/entrypoint.sh bench'
  assert_contains "${bench_dir}/command.txt" '--bench-mode simulation'
  assert_contains "${bench_dir}/command.txt" '--warmup-requests 0'
  if [[ "${profile}" = probe ]]; then
    assert_contains "${bench_dir}/command.txt" '--num-prompts 2'
    assert_contains "${bench_dir}/command.txt" '--max-concurrency 1'
  else
    assert_contains "${bench_dir}/command.txt" '--num-prompts 16'
    assert_contains "${bench_dir}/command.txt" '--max-concurrency 4'
    assert_contains "${bench_dir}/command.txt" '--random-input-len 256'
    assert_contains "${bench_dir}/command.txt" '--random-output-len 32'
  fi
done

FAKE_BENCH_EXIT=23
export FAKE_BENCH_EXIT
if bash "${root_dir}/scripts/run_benchmark.sh" generic probe >/dev/null 2>&1; then
  fail 'benchmark must preserve a nonzero exit status'
fi
[[ "$(<"${run_dir}/benchmark/generic/probe/exit-code.txt")" = 23 ]] || fail 'saved benchmark exit status is wrong'
unset FAKE_BENCH_EXIT

FAKE_SERVER_LOGS='Loading checkpoint shards: 1/4'
export FAKE_SERVER_LOGS
: >"${FAKE_DOCKER_LOG}"
if bash "${root_dir}/scripts/run_benchmark.sh" generic probe >/dev/null 2>&1; then
  fail 'weight loading guard must fail the benchmark'
fi
assert_contains "${run_dir}/benchmark/generic/probe/guard-failure.txt" 'Loading checkpoint shards'
assert_contains "${FAKE_DOCKER_LOG}" 'stop project-container-id'
assert_contains "${FAKE_DOCKER_LOG}" 'rm project-container-id'
unset FAKE_SERVER_LOGS

# Recreate state to exercise the independent real-forward guard.
bash "${root_dir}/scripts/start_server.sh" generic >/dev/null
run_dir="$(<"${state_dir}/run_dir")"
FAKE_SERVER_LOGS='ModelRunner.forward started'
export FAKE_SERVER_LOGS
if bash "${root_dir}/scripts/run_benchmark.sh" generic probe >/dev/null 2>&1; then
  fail 'real-forward guard must fail the benchmark'
fi
assert_contains "${run_dir}/benchmark/generic/probe/guard-failure.txt" 'ModelRunner.forward'
unset FAKE_SERVER_LOGS

# An importable NVIDIA telemetry package is allowed, but CUDA initialization is not.
bash "${root_dir}/scripts/start_server.sh" generic >/dev/null
run_dir="$(<"${state_dir}/run_dir")"
FAKE_SERVER_LOGS='Initializing CUDA runtime'
export FAKE_SERVER_LOGS
if bash "${root_dir}/scripts/run_benchmark.sh" generic probe >/dev/null 2>&1; then
  fail 'CUDA initialization guard must fail the benchmark'
fi
assert_contains "${run_dir}/benchmark/generic/probe/guard-failure.txt" 'Initializing CUDA'
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

printf 'lifecycle script tests passed\n'
