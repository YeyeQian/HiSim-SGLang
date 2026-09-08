#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
tmp_dir="$(mktemp -d)"
trap 'rm -rf "${tmp_dir}"' EXIT

fixture_root="${tmp_dir}/fixture"
fixture_data="${fixture_root}/aic/data/h20_sxm/sglang/0.5.6.post2"
fixture_xgb="${fixture_root}/aic/xgb_models/qwen3_8B"
mkdir -p "${fixture_data}" "${fixture_xgb}"
printf 'device: h20_sxm\n' >"${fixture_root}/aic/h20_sxm.yaml"
printf 'fixture\n' >"${fixture_data}/probe.txt"
printf '{"model":"fixture"}\n' >"${fixture_xgb}/model.json"
(
  cd "${fixture_root}"
  zip -qr "${tmp_dir}/H20_AIC.zip" aic
)
fixture_sha="$(sha256sum "${tmp_dir}/H20_AIC.zip" | awk '{print $1}')"
fixture_size="$(stat -c %s "${tmp_dir}/H20_AIC.zip")"
archive="${tmp_dir}/downloads/H20_AIC.zip"
asset_dir="${tmp_dir}/h20_aic"

run_fetch() {
  H20_AIC_URL="file://${tmp_dir}/H20_AIC.zip" \
    H20_AIC_SHA256="${1}" \
    H20_AIC_SIZE="${2:-${fixture_size}}" \
    H20_AIC_ARCHIVE="${archive}" \
    H20_AIC_DIR="${asset_dir}" \
    bash "${repo_root}/scripts/fetch_h20_data.sh"
}

run_fetch "${fixture_sha}" "${fixture_size}"
test -s "${asset_dir}/aic/h20_sxm.yaml"
test "$(cat "${asset_dir}/aic/data/h20_sxm/sglang/0.5.6.post2/probe.txt")" = fixture
test "$(cat "${asset_dir}/aic/xgb_models/qwen3_8B/model.json")" = '{"model":"fixture"}'

printf 'preserve\n' >"${asset_dir}/sentinel.txt"
run_fetch "${fixture_sha}"
test "$(cat "${asset_dir}/sentinel.txt")" = preserve

# A matching checksum marker must not bless an asset whose required XGB files
# have disappeared. A fresh extraction must restore the complete asset.
rm "${asset_dir}/aic/xgb_models/qwen3_8B/model.json"
run_fetch "${fixture_sha}"
test "$(cat "${asset_dir}/aic/xgb_models/qwen3_8B/model.json")" = '{"model":"fixture"}'
printf 'preserve\n' >"${asset_dir}/sentinel.txt"

# The fixed immutable URL has a separately recorded byte size. Even a file
# with the configured SHA must be rejected when that provenance evidence is
# inconsistent.
if run_fetch "${fixture_sha}" "$((fixture_size + 1))" >/dev/null 2>&1; then
  echo "fetch accepted an archive size mismatch" >&2
  exit 1
fi

bad_sha="$(printf '0%.0s' {1..64})"
if run_fetch "${bad_sha}" "${fixture_size}" >/dev/null 2>&1; then
  echo "fetch accepted a checksum mismatch" >&2
  exit 1
fi
test "$(cat "${asset_dir}/aic/data/h20_sxm/sglang/0.5.6.post2/probe.txt")" = fixture
test "$(cat "${asset_dir}/sentinel.txt")" = preserve

# Network failures get exactly three finite attempts. The fake replaces only
# the external transfer boundary; the downloader's retry behavior is real.
fake_bin="${tmp_dir}/fake-bin"
mkdir -p "${fake_bin}"
cat >"${fake_bin}/curl" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"${FAKE_CURL_LOG}"
exit 22
EOF
chmod +x "${fake_bin}/curl"
fake_curl_log="${tmp_dir}/fake-curl.log"
: >"${fake_curl_log}"
set +e
PATH="${fake_bin}:${PATH}" \
  FAKE_CURL_LOG="${fake_curl_log}" \
  DOCKER_PROJECT_PROXY="http://127.0.0.1:28999" \
  H20_AIC_URL="https://example.invalid/H20_AIC.zip" \
  H20_AIC_SHA256="${bad_sha}" \
  H20_AIC_SIZE=1 \
  H20_AIC_ARCHIVE="${tmp_dir}/retry/H20_AIC.zip" \
  H20_AIC_DIR="${tmp_dir}/retry-asset" \
  bash "${repo_root}/scripts/fetch_h20_data.sh" >/dev/null 2>&1
retry_status=$?
set -e
test "${retry_status}" -ne 0
test "$(wc -l <"${fake_curl_log}")" -eq 3
grep -F -- '--connect-timeout 10' "${fake_curl_log}" >/dev/null
grep -F -- '--max-time 60' "${fake_curl_log}" >/dev/null
grep -F -- '--proxy http://127.0.0.1:28999' "${fake_curl_log}" >/dev/null

echo "test_fetch_h20_data.sh: PASS"
