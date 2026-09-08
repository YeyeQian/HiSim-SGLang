#!/usr/bin/env bash
set -euo pipefail

root_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${root_dir}/configs/versions.env"
patch_file="${root_dir}/patches/sglang/2f4a6add-cpu-fallbacks.patch"

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

[[ "$(git -C "${root_dir}/third_party/sglang" rev-parse HEAD)" = "${SGLANG_COMMIT}" ]] ||
  fail 'SGLang submodule moved from the approved pin'
[[ "${SGLANG_CPU_PATCH_UPSTREAM_COMMIT:-}" = 2f4a6addf3101342498b4528289c6fd053622530 ]] ||
  fail 'upstream CPU patch provenance is not pinned'
[[ -f "${patch_file}" ]] || fail 'tracked SGLang CPU patch is missing'

mapfile -t changed_paths < <(sed -n 's#^diff --git a/[^ ]* b/##p' "${patch_file}")
expected_paths=(
  python/sglang/srt/layers/activation.py
  python/sglang/srt/layers/layernorm.py
  python/sglang/srt/layers/rotary_embedding.py
)
[[ "${changed_paths[*]}" = "${expected_paths[*]}" ]] ||
  fail "patch scope drifted: ${changed_paths[*]}"
[[ "$(grep -c '^@@ ' "${patch_file}")" -eq 3 ]] || fail 'patch must contain exactly three hunks'

git -C "${root_dir}/third_party/sglang" apply --check "${patch_file}" ||
  fail 'patch no longer applies clean to the pinned SGLang source'
grep -F 'COPY patches/sglang/2f4a6add-cpu-fallbacks.patch /tmp/sglang-cpu.patch' \
  "${root_dir}/Dockerfile" >/dev/null || fail 'Dockerfile does not copy the audited patch'
grep -F 'git apply --check --no-index /tmp/sglang-cpu.patch' "${root_dir}/Dockerfile" >/dev/null ||
  fail 'Dockerfile does not fail on patch drift before applying it'
grep -F 'git apply --no-index /tmp/sglang-cpu.patch' "${root_dir}/Dockerfile" >/dev/null ||
  fail 'Dockerfile does not apply the audited patch'

printf 'test_sglang_cpu_patch.sh: PASS\n'
