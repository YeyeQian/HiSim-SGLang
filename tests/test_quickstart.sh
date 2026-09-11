#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
tmp_dir="$(mktemp -d)"
trap 'rm -rf -- "${tmp_dir}"' EXIT

fixture_root="${tmp_dir}/project"
fake_bin="${tmp_dir}/bin"
mkdir -p "${fixture_root}/scripts" "${fixture_root}/tests" "${fake_bin}"
cp "${repo_root}/scripts/quickstart.sh" "${fixture_root}/scripts/quickstart.sh"

cat >"${fake_bin}/git" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf 'submodules:%s\n' "$*" >>"${QUICKSTART_LOG}"
EOF

cat >"${fixture_root}/tests/test_pins.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf 'pins\n' >>"${QUICKSTART_LOG}"
EOF

for script_name in preflight wait_ready; do
  cat >"${fixture_root}/scripts/${script_name}.sh" <<EOF
#!/usr/bin/env bash
set -euo pipefail
printf '${script_name}\n' >>"\${QUICKSTART_LOG}"
exit "\${FAIL_${script_name^^}:-0}"
EOF
done

for script_name in build inspect_image; do
  cat >"${fixture_root}/scripts/${script_name}.sh" <<EOF
#!/usr/bin/env bash
set -euo pipefail
printf '${script_name}:image=%s|%s\n' "\${IMAGE_TAG-<unset>}" "\${HISIM_IMAGE-<unset>}" >>"\${QUICKSTART_LOG}"
exit "\${FAIL_${script_name^^}:-0}"
EOF
done

cat >"${fixture_root}/scripts/start_server.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf 'start:%s|image=%s|%s\n' "$*" "${IMAGE_TAG-<unset>}" "${HISIM_IMAGE-<unset>}" >>"${QUICKSTART_LOG}"
exit "${FAIL_START:-0}"
EOF

cat >"${fixture_root}/scripts/run_benchmark.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf 'benchmark:%s\n' "$*" >>"${QUICKSTART_LOG}"
state_dir="${RESULTS_ROOT}/.state/${HISIM_CONTAINER_NAME:-hisim-sglang-cpu-smoke}"
bench_dir="${RESULTS_ROOT}/run one/benchmark/generic/probe/invocation"
mkdir -p "${state_dir}" "${bench_dir}"
printf '%s\n' "${bench_dir}" >"${state_dir}/last-benchmark-probe"
printf '{}\n' >"${bench_dir}/metrics.json"
printf '{}\n' >"${bench_dir}/provenance.json"
exit "${FAIL_BENCHMARK:-0}"
EOF

cat >"${fixture_root}/scripts/validate_results.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf 'validate:%s|%s|%s|image=%s|%s\n' \
  "$1" "$2" "$3" "${IMAGE_TAG-<unset>}" "${HISIM_IMAGE-<unset>}" >>"${QUICKSTART_LOG}"
exit "${FAIL_VALIDATE:-0}"
EOF

cat >"${fixture_root}/scripts/stop_server.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf 'stop\n' >>"${QUICKSTART_LOG}"
exit "${FAIL_STOP:-0}"
EOF
chmod +x "${fake_bin}/git" "${fixture_root}"/scripts/*.sh "${fixture_root}"/tests/*.sh

export PATH="${fake_bin}:${PATH}"
export QUICKSTART_LOG="${tmp_dir}/quickstart.log"
export RESULTS_ROOT="${tmp_dir}/results"
export HISIM_CONTAINER_NAME=hisim-sglang-cpu-smoke
unset IMAGE_TAG HISIM_IMAGE

: >"${QUICKSTART_LOG}"
env -u IMAGE_TAG -u HISIM_IMAGE bash "${fixture_root}/scripts/quickstart.sh"
expected_bench="${RESULTS_ROOT}/run one/benchmark/generic/probe/invocation"
cat >"${tmp_dir}/expected-success.log" <<EOF
submodules:-C ${fixture_root} submodule update --init --recursive
pins
preflight
build:image=hisim-sglang-cpu:0.5.6.post2|hisim-sglang-cpu:0.5.6.post2
inspect_image:image=hisim-sglang-cpu:0.5.6.post2|hisim-sglang-cpu:0.5.6.post2
start:generic|image=hisim-sglang-cpu:0.5.6.post2|hisim-sglang-cpu:0.5.6.post2
wait_ready
benchmark:generic probe
validate:${expected_bench}|probe|upstream_generic_mock|image=hisim-sglang-cpu:0.5.6.post2|hisim-sglang-cpu:0.5.6.post2
stop
EOF
cmp "${tmp_dir}/expected-success.log" "${QUICKSTART_LOG}"

assert_unified_image() {
  local expected_image="$1"
  for stage in build inspect_image start validate; do
    grep -F "${stage}:" "${QUICKSTART_LOG}" | grep -Fq \
      "image=${expected_image}|${expected_image}" || {
      printf '%s did not receive unified image %s\n' "${stage}" "${expected_image}" >&2
      exit 1
    }
  done
}

: >"${QUICKSTART_LOG}"
env -u HISIM_IMAGE IMAGE_TAG=registry.example/by-tag:test \
  bash "${fixture_root}/scripts/quickstart.sh" >/dev/null
assert_unified_image registry.example/by-tag:test

: >"${QUICKSTART_LOG}"
env -u IMAGE_TAG HISIM_IMAGE=registry.example/by-runtime:test \
  bash "${fixture_root}/scripts/quickstart.sh" >/dev/null
assert_unified_image registry.example/by-runtime:test

: >"${QUICKSTART_LOG}"
IMAGE_TAG=registry.example/same:test HISIM_IMAGE=registry.example/same:test \
  bash "${fixture_root}/scripts/quickstart.sh" >/dev/null
assert_unified_image registry.example/same:test

: >"${QUICKSTART_LOG}"
set +e
IMAGE_TAG=registry.example/build:test HISIM_IMAGE=registry.example/runtime:test \
  bash "${fixture_root}/scripts/quickstart.sh" >"${tmp_dir}/conflict.stdout" 2>"${tmp_dir}/conflict.stderr"
conflict_status=$?
set -e
[[ "${conflict_status}" -ne 0 ]]
[[ ! -s "${QUICKSTART_LOG}" ]]
grep -Fq 'IMAGE_TAG and HISIM_IMAGE must match' "${tmp_dir}/conflict.stderr"

: >"${QUICKSTART_LOG}"
set +e
FAIL_START=19 bash "${fixture_root}/scripts/quickstart.sh" >/dev/null 2>&1
start_status=$?
set -e
[[ "${start_status}" -eq 19 ]]
! grep -Fxq stop "${QUICKSTART_LOG}"

: >"${QUICKSTART_LOG}"
set +e
FAIL_WAIT_READY=23 FAIL_STOP=41 bash "${fixture_root}/scripts/quickstart.sh" >/dev/null 2>&1
readiness_status=$?
set -e
[[ "${readiness_status}" -eq 23 ]]
[[ "$(grep -Fxc stop "${QUICKSTART_LOG}")" -eq 1 ]]
[[ "$(tail -n 2 "${QUICKSTART_LOG}")" = $'wait_ready\nstop' ]]

for forbidden in fetch_h20_data fetch_sharegpt_data small sharegpt; do
  if grep -F -- "${forbidden}" "${QUICKSTART_LOG}" >/dev/null; then
    printf 'quickstart invoked forbidden path: %s\n' "${forbidden}" >&2
    exit 1
  fi
done

printf 'quickstart orchestration tests passed\n'
