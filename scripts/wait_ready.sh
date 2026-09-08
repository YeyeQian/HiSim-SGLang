#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "${script_dir}/lib/common.sh"

repo_root="$(project_root)"
container_name="${HISIM_CONTAINER_NAME:-hisim-sglang-cpu-smoke}"
port="${HISIM_PORT:-30000}"
results_root="${RESULTS_ROOT:-${repo_root}/results}"
state_dir="${results_root}/.state/${container_name}"
timeout_seconds="${READINESS_TIMEOUT_SECONDS:-180}"
interval_seconds="${READINESS_INTERVAL_SECONDS:-2}"
[[ "${timeout_seconds}" =~ ^[0-9]+$ && "${interval_seconds}" =~ ^[0-9]+([.][0-9]+)?$ ]] ||
  die "readiness timeout and interval must be nonnegative numbers"
[[ -s "${state_dir}/container_id" && -s "${state_dir}/run_dir" && -s "${state_dir}/kind" ]] ||
  die "no active project container state exists at ${state_dir}"

container_id="$(<"${state_dir}/container_id")"
run_dir="$(<"${state_dir}/run_dir")"
kind="$(<"${state_dir}/kind")"
server_dir="${run_dir}/server/${kind}"
endpoint="http://127.0.0.1:${port}/health"
readiness_log="${server_dir}/readiness.log"
guard_failure="${server_dir}/runtime-guard-failure.txt"
mkdir -p "${server_dir}"
printf 'endpoint=%s timeout_seconds=%s interval_seconds=%s\n' \
  "${endpoint}" "${timeout_seconds}" "${interval_seconds}" >"${readiness_log}"

capture_failure() {
  docker logs "${container_id}" >"${server_dir}/container.log" 2>&1 || true
  docker inspect "${container_id}" >"${server_dir}/container-inspect.json" 2>&1 || true
  bash "${repo_root}/scripts/stop_server.sh" || true
}

start_epoch="$(date +%s)"
while :; do
  if [[ -s "${guard_failure}" ]]; then
    printf 'runtime guard failed before readiness\n' >>"${readiness_log}"
    bash "${repo_root}/scripts/stop_server.sh" >/dev/null 2>&1 || true
    exit 90
  fi
  running="$(docker inspect --format '{{.State.Running}}' "${container_id}" 2>/dev/null || printf false)"
  if [[ "${running}" != true ]]; then
    status="$(docker inspect --format '{{.State.Status}}' "${container_id}" 2>/dev/null || printf unknown)"
    exit_code="$(docker inspect --format '{{.State.ExitCode}}' "${container_id}" 2>/dev/null || printf unknown)"
    printf 'container exited before readiness: status=%s exit_code=%s\n' "${status}" "${exit_code}" >>"${readiness_log}"
    capture_failure
    exit 1
  fi

  if curl --fail --silent --show-error --connect-timeout 2 --max-time 5 "${endpoint}" >/dev/null; then
    if [[ -s "${guard_failure}" ]]; then
      printf 'runtime guard failed during readiness\n' >>"${readiness_log}"
      bash "${repo_root}/scripts/stop_server.sh" >/dev/null 2>&1 || true
      exit 90
    fi
    printf 'ready_at=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" >>"${readiness_log}"
    printf 'SGLang is ready at %s\n' "${endpoint}"
    exit 0
  fi

  now="$(date +%s)"
  if (( now - start_epoch >= timeout_seconds )); then
    printf 'readiness timed out at %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" >>"${readiness_log}"
    capture_failure
    exit 124
  fi
  sleep "${interval_seconds}"
done
