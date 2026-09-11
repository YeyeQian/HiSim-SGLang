#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
repo_root="$(cd "${script_dir}/.." && pwd -P)"
results_root="${RESULTS_ROOT:-${repo_root}/results}"
container_name="${HISIM_CONTAINER_NAME:-hisim-sglang-cpu-smoke}"
state_dir="${results_root}/.state/${container_name}"
service_started=0

cleanup_started_service() {
  local first_status=$?
  trap - EXIT INT TERM
  if [[ "${service_started}" -eq 1 ]]; then
    bash "${repo_root}/scripts/stop_server.sh" ||
      printf 'WARNING: quickstart cleanup failed after status %s\n' "${first_status}" >&2
  fi
  exit "${first_status}"
}

git -C "${repo_root}" submodule update --init --recursive
bash "${repo_root}/tests/test_pins.sh"
bash "${repo_root}/scripts/preflight.sh"
bash "${repo_root}/scripts/build.sh"
bash "${repo_root}/scripts/inspect_image.sh"

bash "${repo_root}/scripts/start_server.sh" generic
service_started=1
trap cleanup_started_service EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

bash "${repo_root}/scripts/wait_ready.sh"
bash "${repo_root}/scripts/run_benchmark.sh" generic probe
[[ -s "${state_dir}/last-benchmark-probe" ]] || {
  printf 'ERROR: probe benchmark did not record its evidence directory\n' >&2
  exit 1
}
benchmark_dir="$(<"${state_dir}/last-benchmark-probe")"
bash "${repo_root}/scripts/validate_results.sh" \
  "${benchmark_dir}" probe upstream_generic_mock
bash "${repo_root}/scripts/stop_server.sh"

service_started=0
trap - EXIT INT TERM
printf 'Generic random-ids quickstart passed; evidence: %s\n' "${benchmark_dir}"
