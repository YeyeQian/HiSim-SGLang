#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=lib/common.sh
source "${script_dir}/lib/common.sh"

[[ $# -eq 3 ]] ||
  die "usage: $0 BENCHMARK_DIR probe|small|sharegpt CONFIG_KIND"
benchmark_dir="$1"
profile="$2"
config_kind="$3"

case "${profile}:${config_kind}" in
  probe:upstream_generic_mock | small:upstream_generic_mock | \
    probe:official_h20_data_path | small:official_h20_data_path | \
    sharegpt:sharegpt_workload_shape) ;;
  *) die "unsupported profile and config-kind combination: ${profile}:${config_kind}" ;;
esac

[[ -d "${benchmark_dir}" ]] || die "benchmark directory does not exist: ${benchmark_dir}"
benchmark_dir="$(cd "${benchmark_dir}" && pwd -P)"
[[ -f "${benchmark_dir}/metrics.json" ]] ||
  die "benchmark metrics are missing: ${benchmark_dir}/metrics.json"
[[ -f "${benchmark_dir}/provenance.json" ]] ||
  die "benchmark provenance is missing: ${benchmark_dir}/provenance.json"

image="${HISIM_IMAGE:-${IMAGE_TAG:-hisim-sglang-cpu:0.5.6.post2}}"
docker run --rm \
  --volume "${script_dir}/validate_results.py:/run/hisim/validate_results.py:ro" \
  --volume "${benchmark_dir}:/results:rw" \
  --entrypoint python \
  "${image}" /run/hisim/validate_results.py \
  --metrics /results/metrics.json \
  --provenance /results/provenance.json \
  --profile "${profile}" \
  --config-kind "${config_kind}" \
  --output /results/validation.json
