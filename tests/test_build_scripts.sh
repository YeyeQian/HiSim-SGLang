#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
tmp_dir="$(mktemp -d)"
trap 'rm -rf "${tmp_dir}"' EXIT

fixture_root="${tmp_dir}/project"
fake_bin="${tmp_dir}/bin"
mkdir -p "${fixture_root}/scripts/lib" "${fixture_root}/configs" "${fake_bin}"
cp "${repo_root}/scripts/lib/common.sh" "${fixture_root}/scripts/lib/common.sh"
cp "${repo_root}/configs/versions.env" "${fixture_root}/configs/versions.env"
cp "${repo_root}/scripts/build.sh" "${repo_root}/scripts/inspect_image.sh" "${fixture_root}/scripts/"

cat >"${fixture_root}/scripts/preflight.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
touch "${TEST_RECORD_DIR}/preflight-ran"
EOF

cat >"${fake_bin}/docker" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >>"${TEST_RECORD_DIR}/docker-args"

if [[ " $* " == *" build "* ]]; then
  printf 'fixture build output\n'
  exit "${TEST_BUILD_EXIT:-0}"
fi
if [[ " $* " == *" image inspect "* ]]; then
  [[ "${TEST_IMAGE_EXISTS:-1}" = 1 ]] || exit 1
  printf '[{"Id":"sha256:fixture","RepoDigests":[]} ]\n'
  exit 0
fi
if [[ " $* " == *" versions "* ]]; then
  printf '%s\n' \
    'Python: 3.10.12 (/opt/venv/bin/python)' \
    'torch: 2.9.0' \
    'SGLang: 0.5.6.post2' \
    'HiSim: 0.1.0' \
    'torch.cuda.is_available(): False'
  exit 0
fi
if [[ " $* " == *" -m pip freeze "* ]]; then
  printf '%s\n' "${TEST_FREEZE:-sglang==0.5.6.post2}" 'torch==2.9.0+cpu'
  exit 0
fi
if [[ " $* " == *" --entrypoint uname "* ]]; then
  printf 'fixture-kernel\n'
  exit 0
fi
exit 0
EOF
chmod +x "${fixture_root}/scripts/preflight.sh" "${fake_bin}/docker"

record_dir="${tmp_dir}/record"
mkdir -p "${record_dir}"
set +e
PATH="${fake_bin}:${PATH}" \
  TEST_RECORD_DIR="${record_dir}" TEST_BUILD_EXIT=23 \
  DOCKER_PROJECT_PROXY=http://proxy.example.test:3128 \
  IMAGE_TAG=example.test/hisim:fixture DOCKERFILE=Dockerfile.fixture \
  bash "${fixture_root}/scripts/build.sh" >/dev/null 2>&1
build_status=$?
set -e
[[ "${build_status}" -eq 23 ]] || {
  echo "build script did not preserve docker's exit status (got ${build_status})" >&2
  exit 1
}
test -f "${record_dir}/preflight-ran"
grep -Fxq 'fixture build output' "${fixture_root}/logs/docker-build.log"
build_args="$(cat "${record_dir}/docker-args")"
for expected in \
  'build --network host --progress=plain' \
  '--build-arg HTTP_PROXY=http://proxy.example.test:3128' \
  '--build-arg HTTPS_PROXY=http://proxy.example.test:3128' \
  '--build-arg http_proxy=http://proxy.example.test:3128' \
  '--build-arg https_proxy=http://proxy.example.test:3128' \
  '--build-arg AICONFIGURATOR_COMMIT=9f744a1910f317a091c88ade644d61094ea22119' \
  '--file Dockerfile.fixture' \
  '--tag example.test/hisim:fixture'; do
  [[ "${build_args}" == *"${expected}"* ]] || {
    echo "build invocation missing: ${expected}" >&2
    exit 1
  }
done

for proxy_setting in unset empty direct; do
  : >"${record_dir}/docker-args"
  case "${proxy_setting}" in
    unset)
      env -u DOCKER_PROJECT_PROXY PATH="${fake_bin}:${PATH}" TEST_RECORD_DIR="${record_dir}" \
        bash "${fixture_root}/scripts/build.sh" >/dev/null
      ;;
    empty)
      PATH="${fake_bin}:${PATH}" TEST_RECORD_DIR="${record_dir}" DOCKER_PROJECT_PROXY= \
        bash "${fixture_root}/scripts/build.sh" >/dev/null
      ;;
    direct)
      PATH="${fake_bin}:${PATH}" TEST_RECORD_DIR="${record_dir}" DOCKER_PROJECT_PROXY=direct \
        bash "${fixture_root}/scripts/build.sh" >/dev/null
      ;;
  esac
  direct_build_args="$(cat "${record_dir}/docker-args")"
  [[ "${direct_build_args}" = *'build --network host --progress=plain'* ]]
  [[ "${direct_build_args}" != *'HTTP_PROXY'* ]]
  [[ "${direct_build_args}" != *'HTTPS_PROXY'* ]]
  [[ "${direct_build_args}" != *'http_proxy'* ]]
  [[ "${direct_build_args}" != *'https_proxy'* ]]
done

: >"${record_dir}/docker-args"
set +e
PATH="${fake_bin}:${PATH}" TEST_RECORD_DIR="${record_dir}" TEST_IMAGE_EXISTS=0 \
  bash "${fixture_root}/scripts/inspect_image.sh" >/dev/null 2>&1
missing_status=$?
set -e
[[ "${missing_status}" -ne 0 ]] || {
  echo 'inspection accepted a missing image' >&2
  exit 1
}

: >"${record_dir}/docker-args"
PATH="${fake_bin}:${PATH}" TEST_RECORD_DIR="${record_dir}" \
  IMAGE_TAG=example.test/hisim:fixture \
  bash "${fixture_root}/scripts/inspect_image.sh" >/dev/null
test -s "${fixture_root}/artifacts/image/versions.txt"
test -s "${fixture_root}/artifacts/image/pip-freeze.txt"
test -s "${fixture_root}/artifacts/image/image-inspect.json"
test "$(cat "${fixture_root}/artifacts/image/uname-r.txt")" = fixture-kernel
inspect_args="$(cat "${record_dir}/docker-args")"
[[ "${inspect_args}" == *' --entrypoint python example.test/hisim:fixture -c '* ]]
[[ "${inspect_args}" == *' --entrypoint sh example.test/hisim:fixture -c '* ]]
[[ "${inspect_args}" != *'--gpus'* ]]

set +e
PATH="${fake_bin}:${PATH}" TEST_RECORD_DIR="${record_dir}" \
  TEST_FREEZE='NVIDIA_cublas==1.0' \
  bash "${fixture_root}/scripts/inspect_image.sh" >/dev/null 2>&1
forbidden_status=$?
set -e
[[ "${forbidden_status}" -ne 0 ]] || {
  echo 'inspection accepted a forbidden normalized distribution name' >&2
  exit 1
}

PATH="${fake_bin}:${PATH}" TEST_RECORD_DIR="${record_dir}" \
  TEST_FREEZE='nvidia_ml_py==13.610.43' \
  bash "${fixture_root}/scripts/inspect_image.sh" >/dev/null || {
  echo 'inspection rejected the explicitly allowed pure-Python nvidia-ml-py binding' >&2
  exit 1
}

git -C "${repo_root}" check-ignore -q artifacts/image/probe.txt || {
  echo 'artifacts/image/ is not ignored' >&2
  exit 1
}

echo 'test_build_scripts.sh: PASS'
