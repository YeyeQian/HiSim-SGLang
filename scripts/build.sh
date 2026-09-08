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
selected_proxy="$(proxy_url)"

bash "${repo_root}/scripts/preflight.sh"
mkdir -p "${repo_root}/logs"

set +e
docker build --network host --progress=plain \
  --build-arg "HTTP_PROXY=${selected_proxy}" \
  --build-arg "HTTPS_PROXY=${selected_proxy}" \
  --build-arg "http_proxy=${selected_proxy}" \
  --build-arg "https_proxy=${selected_proxy}" \
  --build-arg "AICONFIGURATOR_COMMIT=${AICONFIGURATOR_COMMIT}" \
  --file "${dockerfile}" \
  --tag "${image_tag}" \
  "${repo_root}" 2>&1 | tee "${repo_root}/logs/docker-build.log"
build_status="${PIPESTATUS[0]}"
set -e

exit "${build_status}"
