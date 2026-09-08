#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "${script_dir}/lib/common.sh"

repo_root="$(project_root)"
# shellcheck source=/dev/null
source "${repo_root}/configs/versions.env"

for command_name in docker git curl sha256sum unzip ss; do
  require_command "${command_name}"
done

docker_root="$(docker info --format '{{.DockerRootDir}}' 2>/dev/null)" ||
  die "cannot access the Docker daemon; ensure Docker is running and your user has access"
[[ -n "${docker_root}" ]] || die "Docker reported an empty DockerRootDir"

selected_proxy="$(proxy_url)"
if [[ "${selected_proxy}" =~ ^http://([^/:]+):([0-9]+)/?$ ]]; then
  proxy_host="${BASH_REMATCH[1]}"
  proxy_port="${BASH_REMATCH[2]}"
else
  die "unsupported proxy URL '${selected_proxy}'; expected http://HOST:PORT"
fi
if ! ss -ltnH "sport = :${proxy_port}" | grep -q .; then
  die "proxy ${proxy_host}:${proxy_port} is not listening"
fi

require_free_kib() {
  local path="$1"
  local required_kib="$2"
  local description="$3"
  local available_kib

  available_kib="$(df -Pk -- "${path}" | awk 'NR == 2 {print $4}')"
  [[ -n "${available_kib}" ]] || die "could not determine free space for ${description} at ${path}"
  if (( available_kib < required_kib )); then
    die "${description} needs at least $((required_kib / 1024 / 1024)) GiB free at ${path}; found $((available_kib / 1024 / 1024)) GiB"
  fi
}

require_free_kib "${repo_root}" $((40 * 1024 * 1024)) "project filesystem"
require_free_kib "${docker_root}" $((20 * 1024 * 1024)) "Docker filesystem"

service_port="${HISIM_PORT:-30000}"
require_free_port "${service_port}"

check_submodule_head() {
  local path="$1"
  local expected="$2"
  local actual

  actual="$(git -C "${repo_root}/${path}" rev-parse HEAD 2>/dev/null)" ||
    die "submodule ${path} is unavailable; initialize submodules and retry"
  [[ "${actual}" = "${expected}" ]] ||
    die "submodule ${path} is at ${actual}, expected ${expected} from configs/versions.env"
}

check_submodule_head third_party/tair-kvcache "${TAIR_KVCACHE_COMMIT}"
check_submodule_head third_party/sglang "${SGLANG_COMMIT}"

printf 'Preflight passed: Docker, proxy, storage, port, and submodule pins are ready.\n'
