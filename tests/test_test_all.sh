#!/usr/bin/env bash
set -euo pipefail

root_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
tmp_dir="$(mktemp -d)"
trap 'rm -rf -- "${tmp_dir}"' EXIT
mkdir -p "${tmp_dir}/tests"

cat >"${tmp_dir}/tests/test_01_fail.sh" <<'EOF'
#!/usr/bin/env bash
printf 'shell-fail-ran\n' >>"${TEST_ALL_SENTINEL}"
exit 7
EOF
cat >"${tmp_dir}/tests/test_02_pass.sh" <<'EOF'
#!/usr/bin/env bash
printf 'shell-pass-ran\n' >>"${TEST_ALL_SENTINEL}"
EOF
cat >"${tmp_dir}/tests/test_fixture.py" <<'EOF'
import os
import unittest


class FixtureTest(unittest.TestCase):
    def test_python_suite_runs_after_shell_failure(self):
        with open(os.environ["TEST_ALL_SENTINEL"], "a", encoding="utf-8") as stream:
            stream.write("python-ran\n")
EOF

set +e
TEST_ALL_ROOT="${tmp_dir}" TEST_ALL_SENTINEL="${tmp_dir}/sentinel" \
  bash "${root_dir}/scripts/test_all.sh" >"${tmp_dir}/stdout" 2>"${tmp_dir}/stderr"
status=$?
set -e

test "${status}" -ne 0
grep -Fxq shell-fail-ran "${tmp_dir}/sentinel"
grep -Fxq shell-pass-ran "${tmp_dir}/sentinel"
grep -Fxq python-ran "${tmp_dir}/sentinel"
grep -Fq 'FAIL:' "${tmp_dir}/stdout"
grep -Fq 'aggregate test suite failed' "${tmp_dir}/stderr"

printf 'test_all aggregation tests passed\n'
