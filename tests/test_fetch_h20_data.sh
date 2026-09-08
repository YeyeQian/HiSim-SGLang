#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
tmp_dir="$(mktemp -d)"
trap 'rm -rf "${tmp_dir}"' EXIT

fixture_root="${tmp_dir}/fixture"
fixture_data="${fixture_root}/aic/data/h20_sxm/sglang/0.5.6.post2"
mkdir -p "${fixture_data}"
printf 'fixture\n' >"${fixture_data}/probe.txt"
(
  cd "${fixture_root}"
  zip -qr "${tmp_dir}/H20_AIC.zip" aic
)
fixture_sha="$(sha256sum "${tmp_dir}/H20_AIC.zip" | awk '{print $1}')"
archive="${tmp_dir}/downloads/H20_AIC.zip"
asset_dir="${tmp_dir}/h20_aic"

run_fetch() {
  H20_AIC_URL="file://${tmp_dir}/H20_AIC.zip" \
    H20_AIC_SHA256="${1}" \
    H20_AIC_ARCHIVE="${archive}" \
    H20_AIC_DIR="${asset_dir}" \
    bash "${repo_root}/scripts/fetch_h20_data.sh"
}

run_fetch "${fixture_sha}"
test "$(cat "${asset_dir}/aic/data/h20_sxm/sglang/0.5.6.post2/probe.txt")" = fixture

printf 'preserve\n' >"${asset_dir}/sentinel.txt"
run_fetch "${fixture_sha}"
test "$(cat "${asset_dir}/sentinel.txt")" = preserve

bad_sha="$(printf '0%.0s' {1..64})"
if run_fetch "${bad_sha}" >/dev/null 2>&1; then
  echo "fetch accepted a checksum mismatch" >&2
  exit 1
fi
test "$(cat "${asset_dir}/aic/data/h20_sxm/sglang/0.5.6.post2/probe.txt")" = fixture
test "$(cat "${asset_dir}/sentinel.txt")" = preserve

echo "test_fetch_h20_data.sh: PASS"
