#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "${script_dir}/lib/common.sh"

repo_root="$(project_root)"
sha_override="${H20_AIC_SHA256-}"
# shellcheck source=/dev/null
source "${repo_root}/configs/versions.env"

url="${H20_AIC_URL:-https://raw.githubusercontent.com/kunluninsight/LatencyPrism/d242ca5b8d7217e1d235d2fb225ff4a8ba24995a/Hisim/Data/H20_AIC.zip}"
expected_sha="${sha_override:-${H20_AIC_SHA256}}"
archive="${H20_AIC_ARCHIVE:-${repo_root}/artifacts/downloads/H20_AIC.zip}"
asset_dir="${H20_AIC_DIR:-${repo_root}/artifacts/h20_aic}"
data_relative="aic/data/h20_sxm/sglang/0.5.6.post2"
marker_name=".H20_AIC.sha256"

require_command curl
require_command sha256sum
require_command unzip

if [[ -d "${asset_dir}/${data_relative}" && -f "${asset_dir}/${marker_name}" ]] &&
  [[ "$(<"${asset_dir}/${marker_name}")" = "${expected_sha}" ]]; then
  printf 'H20 AIC data already verified at %s\n' "${asset_dir}"
  exit 0
fi

archive_parent="$(dirname "${archive}")"
asset_parent="$(dirname "${asset_dir}")"
mkdir -p "${archive_parent}" "${asset_parent}"
partial="${archive}.partial"
extract_tmp=""
backup=""
cleanup() {
  rm -f -- "${partial}"
  if [[ -n "${extract_tmp}" && -d "${extract_tmp}" ]]; then
    rm -rf -- "${extract_tmp}"
  fi
  if [[ -n "${backup}" && -d "${backup}" ]]; then
    if [[ -e "${asset_dir}" ]]; then
      rm -rf -- "${backup}"
    else
      mv -- "${backup}" "${asset_dir}"
    fi
  fi
}
trap cleanup EXIT

actual_sha=""
if [[ -f "${archive}" ]]; then
  actual_sha="$(sha256sum "${archive}" | awk '{print $1}')"
fi
if [[ "${actual_sha}" != "${expected_sha}" ]]; then
  rm -f -- "${partial}"
  curl --fail --location --silent --show-error --output "${partial}" "${url}"
  actual_sha="$(sha256sum "${partial}" | awk '{print $1}')"
  [[ "${actual_sha}" = "${expected_sha}" ]] ||
    die "H20_AIC.zip checksum mismatch: expected ${expected_sha}, got ${actual_sha}"
  mv -f -- "${partial}" "${archive}"
fi

extract_tmp="$(mktemp -d "${asset_parent}/.$(basename "${asset_dir}").tmp.XXXXXX")"
unzip -q "${archive}" -d "${extract_tmp}"
[[ -d "${extract_tmp}/${data_relative}" ]] ||
  die "H20_AIC.zip is missing expected directory ${data_relative}"
printf '%s\n' "${expected_sha}" >"${extract_tmp}/${marker_name}"

if [[ -e "${asset_dir}" ]]; then
  backup="${asset_parent}/.$(basename "${asset_dir}").previous.$$"
  mv -- "${asset_dir}" "${backup}"
fi
if ! mv -- "${extract_tmp}" "${asset_dir}"; then
  if [[ -n "${backup}" && -d "${backup}" ]]; then
    mv -- "${backup}" "${asset_dir}"
    backup=""
  fi
  die "could not install verified H20 AIC data at ${asset_dir}"
fi
extract_tmp=""
if [[ -n "${backup}" ]]; then
  rm -rf -- "${backup}"
  backup=""
fi

printf 'Verified H20 AIC data installed at %s\n' "${asset_dir}"
