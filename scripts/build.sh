#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "${script_dir}/lib/common.sh"

repo_root="$(project_root)"
# shellcheck source=/dev/null
source "${repo_root}/configs/versions.env"

image_tag="${IMAGE_TAG:-hisim-sglang-cpu:0.5.6.post2}"
dockerfile="${DOCKERFILE:-Dockerfile}"

bash "${repo_root}/scripts/preflight.sh"
mkdir -p "${repo_root}/logs"

set +e
build_args=(build --network host --progress=plain)
append_docker_build_proxy_args build_args
build_args+=(
  --build-arg "AICONFIGURATOR_COMMIT=${AICONFIGURATOR_COMMIT}" \
  --file "${dockerfile}" \
  --tag "${image_tag}" \
  "${repo_root}"
)
docker "${build_args[@]}" 2>&1 | tee "${repo_root}/logs/docker-build.log"
build_status="${PIPESTATUS[0]}"
set -e

exit "${build_status}"
