#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "${script_dir}/lib/common.sh"

repo_root="$(project_root)"
container_name="${HISIM_CONTAINER_NAME:-hisim-sglang-cpu-smoke}"
results_root="${RESULTS_ROOT:-${repo_root}/results}"
cache_dir="${HF_CACHE_DIR:-${repo_root}/cache/huggingface}"
state_dir="${results_root}/.state/${container_name}"

if [[ ! -s "${state_dir}/container_id" ]]; then
  printf 'No active project container state for %s.\n' "${container_name}"
  exit 0
fi

container_id="$(<"${state_dir}/container_id")"
run_dir="$(<"${state_dir}/run_dir")"
kind="$(<"${state_dir}/kind")"
server_dir="${run_dir}/server/${kind}"
mkdir -p "${server_dir}"

actual_id="$(docker inspect --format '{{.Id}}' "${container_name}" 2>/dev/null || true)"
if [[ -z "${actual_id}" ]]; then
  printf 'Recorded container %s no longer exists; preserving state evidence.\n' "${container_id}"
  rm -f "${state_dir}/container_id" "${state_dir}/container_name" "${state_dir}/kind" "${state_dir}/run_dir"
  rmdir "${state_dir}" 2>/dev/null || true
  exit 0
fi
[[ "${actual_id}" = "${container_id}" ]] ||
  die "refusing cleanup: ${container_name} resolves to ${actual_id}, recorded project ID is ${container_id}"

docker logs "${container_id}" >"${server_dir}/container-final.log" 2>&1 || true
docker inspect "${container_id}" >"${server_dir}/container-final-inspect.json" 2>&1 || true
du -sk -- "${cache_dir}" >"${server_dir}/cache-final.txt" 2>/dev/null || true
printf '%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" >"${server_dir}/stopped-at.txt"

docker stop "${container_id}" >/dev/null
docker rm "${container_id}" >/dev/null
rm -f "${state_dir}/container_id" "${state_dir}/container_name" "${state_dir}/kind" "${state_dir}/run_dir"
rmdir "${state_dir}" 2>/dev/null || true
printf 'Stopped and removed project container %s (%s).\n' "${container_name}" "${container_id}"
