#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
tmp_dir="$(mktemp -d)"
trap 'rm -rf "${tmp_dir}"' EXIT

fixture="${tmp_dir}/sharegpt.json"
printf '[{"conversations":[{"from":"human","value":"hello"},{"from":"gpt","value":"world"}]}]\n' >"${fixture}"
fixture_sha="$(sha256sum "${fixture}" | awk '{print $1}')"
fixture_size="$(stat -c %s "${fixture}")"
dataset="${tmp_dir}/downloads/sharegpt.json"

run_fetch() {
  SHAREGPT_URL="file://${fixture}" \
    SHAREGPT_SHA256="${1:-${fixture_sha}}" \
    SHAREGPT_SIZE="${2:-${fixture_size}}" \
    SHAREGPT_DATASET="${dataset}" \
    bash "${repo_root}/scripts/fetch_sharegpt_data.sh"
}

# A verified transfer is atomically installed and leaves no partial file.
run_fetch
test "$(sha256sum "${dataset}" | awk '{print $1}')" = "${fixture_sha}"
test "$(stat -c %s "${dataset}")" = "${fixture_size}"
test ! -e "${dataset}.partial"

# A valid cached final file is revalidated and reused without network access.
mv "${fixture}" "${fixture}.offline"
printf 'stale-partial\n' >"${dataset}.partial"
run_fetch
test ! -e "${dataset}.partial"
mv "${fixture}.offline" "${fixture}"

# Neither an invalid size nor an invalid digest is accepted as ready.
if run_fetch "${fixture_sha}" "$((fixture_size + 1))" >/dev/null 2>&1; then
  echo 'fetch accepted an invalid dataset size' >&2
  exit 1
fi
bad_sha="$(printf '0%.0s' {1..64})"
if run_fetch "${bad_sha}" "${fixture_size}" >/dev/null 2>&1; then
  echo 'fetch accepted an invalid dataset checksum' >&2
  exit 1
fi

# A failed bounded transfer cannot replace an existing file or leave a partial.
printf 'old-invalid-content\n' >"${dataset}"
old_sha="$(sha256sum "${dataset}" | awk '{print $1}')"
fake_bin="${tmp_dir}/fake-bin"
mkdir -p "${fake_bin}"
cat >"${fake_bin}/curl" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"${FAKE_CURL_LOG}"
output=''
while [[ $# -gt 0 ]]; do
  if [[ "$1" = --output ]]; then output="$2"; shift 2; else shift; fi
done
printf 'interrupted\n' >"${output}"
exit 22
EOF
chmod +x "${fake_bin}/curl"
fake_curl_log="${tmp_dir}/curl.log"
: >"${fake_curl_log}"
set +e
PATH="${fake_bin}:${PATH}" \
  FAKE_CURL_LOG="${fake_curl_log}" \
  DOCKER_PROJECT_PROXY='http://proxy.example:17897' \
  SHAREGPT_URL='https://example.invalid/sharegpt.json' \
  SHAREGPT_SHA256="${fixture_sha}" \
  SHAREGPT_SIZE="${fixture_size}" \
  SHAREGPT_DATASET="${dataset}" \
  bash "${repo_root}/scripts/fetch_sharegpt_data.sh" >/dev/null 2>&1
status=$?
set -e
test "${status}" -ne 0
test "$(sha256sum "${dataset}" | awk '{print $1}')" = "${old_sha}"
test ! -e "${dataset}.partial"
test "$(wc -l <"${fake_curl_log}")" -eq 1
grep -F -- '--proxy http://proxy.example:17897' "${fake_curl_log}" >/dev/null
grep -F -- '--connect-timeout 10' "${fake_curl_log}" >/dev/null
grep -F -- '--max-time 1800' "${fake_curl_log}" >/dev/null
grep -F -- '--retry 2' "${fake_curl_log}" >/dev/null
grep -F -- '--retry-max-time 5400' "${fake_curl_log}" >/dev/null
if grep -E -- '(^| )(-k|--insecure)( |$)' "${fake_curl_log}" >/dev/null; then
  echo 'fetch disabled TLS verification' >&2
  exit 1
fi

for proxy_setting in unset empty direct; do
  : >"${fake_curl_log}"
  direct_dataset="${tmp_dir}/${proxy_setting}/sharegpt.json"
  set +e
  case "${proxy_setting}" in
    unset)
      env -u DOCKER_PROJECT_PROXY PATH="${fake_bin}:${PATH}" FAKE_CURL_LOG="${fake_curl_log}" \
        SHAREGPT_URL='https://example.invalid/sharegpt.json' SHAREGPT_SHA256="${fixture_sha}" \
        SHAREGPT_SIZE="${fixture_size}" SHAREGPT_DATASET="${direct_dataset}" \
        bash "${repo_root}/scripts/fetch_sharegpt_data.sh" >/dev/null 2>&1
      ;;
    empty | direct)
      PATH="${fake_bin}:${PATH}" FAKE_CURL_LOG="${fake_curl_log}" DOCKER_PROJECT_PROXY="${proxy_setting/empty/}" \
        SHAREGPT_URL='https://example.invalid/sharegpt.json' SHAREGPT_SHA256="${fixture_sha}" \
        SHAREGPT_SIZE="${fixture_size}" SHAREGPT_DATASET="${direct_dataset}" \
        bash "${repo_root}/scripts/fetch_sharegpt_data.sh" >/dev/null 2>&1
      ;;
  esac
  direct_status=$?
  set -e
  test "${direct_status}" -ne 0
  test "$(wc -l <"${fake_curl_log}")" -eq 1
  if grep -F -- '--proxy' "${fake_curl_log}" >/dev/null; then
    echo "${proxy_setting} direct download unexpectedly passed a proxy argument" >&2
    exit 1
  fi
done

echo 'test_fetch_sharegpt_data.sh: PASS'
