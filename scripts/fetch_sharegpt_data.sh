#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "${script_dir}/lib/common.sh"

repo_root="$(project_root)"
url_override="${SHAREGPT_URL-}"
sha_override="${SHAREGPT_SHA256-}"
size_override="${SHAREGPT_SIZE-}"
# shellcheck source=/dev/null
source "${repo_root}/configs/versions.env"

url="${url_override:-${SHAREGPT_URL}}"
expected_sha="${sha_override:-${SHAREGPT_SHA256}}"
expected_size="${size_override:-${SHAREGPT_SIZE}}"
dataset="${SHAREGPT_DATASET:-${repo_root}/artifacts/downloads/ShareGPT_V3_unfiltered_cleaned_split.json}"
partial="${dataset}.partial"

require_command curl
require_command sha256sum
[[ "${expected_size}" =~ ^[1-9][0-9]*$ ]] || die "SHAREGPT_SIZE must be a positive integer"
[[ "${expected_sha}" =~ ^[0-9a-f]{64}$ ]] || die "SHAREGPT_SHA256 must be a lowercase SHA256 digest"

dataset_matches() {
  local candidate="$1"
  [[ -f "${candidate}" ]] &&
    [[ "$(stat -c %s "${candidate}")" = "${expected_size}" ]] &&
    [[ "$(sha256sum "${candidate}" | awk '{print $1}')" = "${expected_sha}" ]]
}

rm -f -- "${partial}"
if dataset_matches "${dataset}"; then
  printf 'ShareGPT dataset already verified at %s\n' "${dataset}"
  exit 0
fi

mkdir -p "$(dirname "${dataset}")"
cleanup() {
  rm -f -- "${partial}"
}
trap cleanup EXIT

proxy="$(proxy_url)"
curl --fail --location --silent --show-error \
  --proxy "${proxy}" \
  --connect-timeout 10 --max-time 1800 \
  --retry 2 --retry-delay 2 --retry-max-time 5400 \
  --output "${partial}" "${url}" ||
  die "ShareGPT download failed after bounded retries"

actual_size="$(stat -c %s "${partial}")"
[[ "${actual_size}" = "${expected_size}" ]] ||
  die "ShareGPT size mismatch: expected ${expected_size} bytes, got ${actual_size}"
actual_sha="$(sha256sum "${partial}" | awk '{print $1}')"
[[ "${actual_sha}" = "${expected_sha}" ]] ||
  die "ShareGPT checksum mismatch: expected ${expected_sha}, got ${actual_sha}"

mv -f -- "${partial}" "${dataset}"
trap - EXIT
printf 'Verified ShareGPT dataset installed at %s\n' "${dataset}"
