#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
tmp_dir="$(mktemp -d)"
trap 'rm -rf -- "${tmp_dir}"' EXIT

fake_bin="${tmp_dir}/fake bin"
benchmark_dir="${tmp_dir}/benchmark result"
mkdir -p "${fake_bin}" "${benchmark_dir}"
printf '{}\n' >"${benchmark_dir}/metrics.json"
printf '{}\n' >"${benchmark_dir}/provenance.json"

cat >"${fake_bin}/docker" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '<%s>\n' "$@" >"${DOCKER_ARGS_LOG}"
EOF
chmod +x "${fake_bin}/docker"

PATH="${fake_bin}:${PATH}" DOCKER_ARGS_LOG="${tmp_dir}/docker.args" \
  HISIM_IMAGE='registry.example/hisim:test' \
  bash "${repo_root}/scripts/validate_results.sh" \
    "${benchmark_dir}" probe upstream_generic_mock

expected_args="${tmp_dir}/expected.args"
cat >"${expected_args}" <<EOF
<run>
<--rm>
<--volume>
<${repo_root}/scripts/validate_results.py:/run/hisim/validate_results.py:ro>
<--volume>
<${benchmark_dir}:/results:rw>
<--entrypoint>
<python>
<registry.example/hisim:test>
</run/hisim/validate_results.py>
<--metrics>
</results/metrics.json>
<--provenance>
</results/provenance.json>
<--profile>
<probe>
<--config-kind>
<upstream_generic_mock>
<--output>
</results/validation.json>
EOF
cmp "${expected_args}" "${tmp_dir}/docker.args"

if PATH="${fake_bin}:${PATH}" DOCKER_ARGS_LOG="${tmp_dir}/unused.args" \
  bash "${repo_root}/scripts/validate_results.sh" \
    "${benchmark_dir}" 'probe;touch bad' upstream_generic_mock >/dev/null 2>&1; then
  printf 'wrapper accepted an unsafe profile argument\n' >&2
  exit 1
fi
[[ ! -e "${tmp_dir}/unused.args" ]]

printf 'validate_results wrapper tests passed\n'
