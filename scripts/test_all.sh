#!/usr/bin/env bash
set -uo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="${TEST_ALL_ROOT:-$(cd "${script_dir}/.." && pwd)}"
tests_dir="${repo_root}/tests"
overall_status=0

while IFS= read -r -d '' test_script; do
  relative_path="${test_script#"${repo_root}/"}"
  if ! bash -n "${test_script}"; then
    printf 'SYNTAX FAIL: %s\n' "${relative_path}"
    overall_status=1
    continue
  fi
  if bash "${test_script}"; then
    printf 'PASS: %s\n' "${relative_path}"
  else
    printf 'FAIL: %s\n' "${relative_path}"
    overall_status=1
  fi
done < <(find "${tests_dir}" -maxdepth 1 -type f -name 'test_*.sh' -print0 | sort -z)

if python3 -m unittest discover -s "${tests_dir}" -p 'test_*.py' -v; then
  printf 'PASS: Python unit tests\n'
else
  printf 'FAIL: Python unit tests\n'
  overall_status=1
fi

if [[ "${overall_status}" -ne 0 ]]; then
  printf 'ERROR: aggregate test suite failed\n' >&2
  exit "${overall_status}"
fi

printf 'All shell orchestration tests and Python unit tests passed.\n'
