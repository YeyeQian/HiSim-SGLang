#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "${script_dir}/lib/common.sh"

repo_root="$(project_root)"
# shellcheck source=/dev/null
source "${repo_root}/configs/versions.env"

image_tag="${IMAGE_TAG:-hisim-sglang-cpu:0.5.6.post2}"
artifact_dir="${repo_root}/artifacts/image"

docker image inspect "${image_tag}" >/dev/null 2>&1 ||
  die "image '${image_tag}' does not exist; build it before inspection"

mkdir -p "${artifact_dir}"
docker run --rm "${image_tag}" versions |
  tee "${artifact_dir}/versions.txt"
docker run --rm --entrypoint python "${image_tag}" -m pip freeze |
  tee "${artifact_dir}/pip-freeze.txt"
docker run --rm --entrypoint uname "${image_tag}" -r |
  tee "${artifact_dir}/uname-r.txt"
docker image inspect "${image_tag}" >"${artifact_dir}/image-inspect.json"

grep -Fxq "SGLang: ${SGLANG_VERSION}" "${artifact_dir}/versions.txt" ||
  die "image does not report required SGLang ${SGLANG_VERSION}"
grep -Fxq 'torch.cuda.is_available(): False' "${artifact_dir}/versions.txt" ||
  die 'image does not report torch.cuda.is_available() as exactly False'

if awk -F '==| @ ' '
  /^[A-Za-z0-9_.-]+(==| @ )/ {
    name = tolower($1)
    gsub(/[_.]+/, "-", name)
    if ((name ~ /^nvidia-/ && name != "nvidia-ml-py") || name == "cuda-python" ||
        name == "flashinfer-python" || name == "flashinfer-cubin") {
      print name
      found = 1
    }
  }
  END { exit !found }
' "${artifact_dir}/pip-freeze.txt" >"${artifact_dir}/forbidden-distributions.txt"; then
  die "forbidden accelerator distributions found: $(tr '\n' ' ' <"${artifact_dir}/forbidden-distributions.txt")"
fi
rm -f "${artifact_dir}/forbidden-distributions.txt"

docker run --rm --entrypoint python "${image_tag}" -c '
import importlib.metadata
import re

import hisim
import torch

cuda_available = torch.cuda.is_available()
if cuda_available is not False:
    raise SystemExit(f"torch.cuda.is_available() must be exactly False, got {cuda_available!r}")

sglang_version = importlib.metadata.version("sglang")
if sglang_version != "'"${SGLANG_VERSION}"'":
    raise SystemExit(f"unexpected SGLang version: {sglang_version}")

forbidden = []
for distribution in importlib.metadata.distributions():
    name = re.sub(r"[-_.]+", "-", distribution.metadata["Name"]).lower()
    if (name.startswith("nvidia-") and name != "nvidia-ml-py") or name in {
        "cuda-python", "flashinfer-python", "flashinfer-cubin"
    }:
        forbidden.append(name)
if forbidden:
    raise SystemExit("forbidden distributions: " + ", ".join(sorted(set(forbidden))))

print(f"HiSim import: {hisim.__name__}")
print(f"SGLang distribution: {sglang_version}")
print(f"torch.cuda.is_available(): {cuda_available}")
print("Forbidden accelerator distributions: absent")
' | tee "${artifact_dir}/runtime-checks.txt"

docker run --rm --entrypoint sh "${image_tag}" -c '
set -- /dev/nvidia*
if [ -e "$1" ]; then
  printf "unexpected NVIDIA device: %s\n" "$1" >&2
  exit 1
fi
printf "/dev/nvidia*: absent\n"
' | tee -a "${artifact_dir}/runtime-checks.txt"

docker run --rm --entrypoint sh \
  --env "EXPECTED_AICONFIGURATOR_COMMIT=${AICONFIGURATOR_COMMIT}" \
  "${image_tag}" -c '
actual_commit="$(git -c safe.directory=/opt/src/aiconfigurator -C /opt/src/aiconfigurator rev-parse HEAD)"
if [ "${actual_commit}" != "${EXPECTED_AICONFIGURATOR_COMMIT}" ]; then
  echo "unexpected AIConfigurator commit: ${actual_commit}" >&2
  exit 1
fi
data_dir=/opt/venv/lib/python3.10/site-packages/aiconfigurator/systems/data/h100_sxm
if [ ! -d "${data_dir}" ]; then
  echo "AIConfigurator installed performance data is missing: ${data_dir}" >&2
  exit 1
fi
if pointers="$(grep -RIl --include="*.txt" "^version https://git-lfs.github.com/spec/v1$" "${data_dir}")"; then
  echo "AIConfigurator performance data is still a Git LFS pointer: ${pointers}" >&2
  exit 1
fi
printf "AIConfigurator commit: %s\n" "${actual_commit}"
printf "git-lfs version: %s\n" "$(git lfs version)"
printf "AIConfigurator performance data: materialized\n"
' | tee -a "${artifact_dir}/runtime-checks.txt"
