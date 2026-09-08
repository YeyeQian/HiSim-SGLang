#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
dockerfile="${repo_root}/Dockerfile"
entrypoint="${repo_root}/docker/entrypoint.sh"

fail() {
  echo "test_dockerfile.sh: $*" >&2
  exit 1
}

require_literal() {
  local file="$1"
  local literal="$2"
  grep -Fq -- "${literal}" "${file}" || fail "${file#"${repo_root}/"} is missing: ${literal}"
}

[[ -f "${dockerfile}" ]] || fail "Dockerfile is missing"
[[ -f "${entrypoint}" ]] || fail "docker/entrypoint.sh is missing"

require_literal "${dockerfile}" 'FROM ubuntu:22.04@sha256:3b06811b2afd352be909dd088a004166d665dc76d38b13eada33522a9d915c6f'
require_literal "${dockerfile}" 'ARG AICONFIGURATOR_COMMIT=9f744a1910f317a091c88ade644d61094ea22119'
require_literal "${dockerfile}" 'https://download.pytorch.org/whl/cpu'
require_literal "${dockerfile}" 'torch==2.9.0'
require_literal "${dockerfile}" 'torchvision==0.24.0'
require_literal "${dockerfile}" 'triton==3.5.0'
require_literal "${dockerfile}" 'COPY third_party/sglang'
require_literal "${dockerfile}" 'cp python/pyproject_cpu.toml python/pyproject.toml'
require_literal "${dockerfile}" 'cp sgl-kernel/pyproject_cpu.toml sgl-kernel/pyproject.toml'
require_literal "${dockerfile}" 'git+https://github.com/ai-dynamo/aiconfigurator.git@${AICONFIGURATOR_COMMIT}'
require_literal "${dockerfile}" 'third_party/tair-kvcache/hisim'
require_literal "${dockerfile}" 'pip install --no-deps'
require_literal "${dockerfile}" 'SGLANG_USE_CPU_ENGINE=1'
require_literal "${dockerfile}" 'FLASHINFER_DISABLE_VERSION_CHECK=1'
require_literal "${dockerfile}" 'PYTHONUNBUFFERED=1'
require_literal "${dockerfile}" 'PATH="/opt/venv/bin:${PATH}"'
require_literal "${dockerfile}" 'apt-get install --no-install-recommends'
require_literal "${dockerfile}" 'rm -rf /var/lib/apt/lists/*'
require_literal "${dockerfile}" 'USER app'
require_literal "${dockerfile}" 'WORKDIR /workspace'
require_literal "${dockerfile}" 'ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]'

docker_instructions="$(sed '/^[[:space:]]*#/d' "${dockerfile}")"
if grep -Eqi -- '(^|[[:space:]])--gpus([=[:space:]]|$)|cuda-|nvidia-|(^|/)(rocm|cuda|xpu)(:|/)' <<<"${docker_instructions}"; then
  fail "Dockerfile contains a forbidden accelerator dependency, image, or flag"
fi

require_literal "${entrypoint}" 'set -euo pipefail'
for command_case in 'server)' 'bench)' 'versions)' 'shell)'; do
  require_literal "${entrypoint}" "${command_case}"
done
require_literal "${entrypoint}" 'hisim.simulation.sglang.launch_server'
require_literal "${entrypoint}" 'hisim.simulation.bench_serving'
require_literal "${entrypoint}" '--device cpu'
require_literal "${entrypoint}" '--skip-server-warmup'
require_literal "${entrypoint}" '--bench-mode simulation'
require_literal "${entrypoint}" '--warmup-requests 0'
require_literal "${entrypoint}" 'exec "$@"'
require_literal "${entrypoint}" 'Python:'
require_literal "${entrypoint}" 'torch:'
require_literal "${entrypoint}" 'SGLang:'
require_literal "${entrypoint}" 'HiSim:'
require_literal "${entrypoint}" 'AIConfigurator:'
require_literal "${entrypoint}" 'torch.cuda.is_available()'
require_literal "${entrypoint}" 'platform:'
require_literal "${entrypoint}" 'getattr(module, "__version__", "unknown")'

entrypoint_commands="$(sed '/^[[:space:]]*#/d' "${entrypoint}")"
if grep -Eqi -- '(^|[[:space:]])--gpus([=[:space:]]|$)|--device[=[:space:]]+(cuda|rocm|xpu)' <<<"${entrypoint_commands}"; then
  fail "entrypoint contains a forbidden accelerator flag"
fi

tmp_dir="$(mktemp -d)"
trap 'rm -rf "${tmp_dir}"' EXIT
mkdir -p "${tmp_dir}/bin"
cat >"${tmp_dir}/bin/python" <<'PYTHON_STUB'
#!/usr/bin/env bash
printf '%s\n' "$@" >"${ENTRYPOINT_ARGS_FILE}"
PYTHON_STUB
chmod +x "${tmp_dir}/bin/python"

if PATH="${tmp_dir}/bin:${PATH}" "${entrypoint}" server >"${tmp_dir}/missing.out" 2>&1; then
  fail "server accepted a missing HISIM_CONFIG_PATH"
fi
grep -Fq 'HISIM_CONFIG_PATH is required' "${tmp_dir}/missing.out" || fail "missing config error is unclear"

if PATH="${tmp_dir}/bin:${PATH}" HISIM_CONFIG_PATH="${tmp_dir}/absent.json" \
  "${entrypoint}" server >"${tmp_dir}/absent.out" 2>&1; then
  fail "server accepted a nonexistent HISIM_CONFIG_PATH"
fi
grep -Fq 'does not exist' "${tmp_dir}/absent.out" || fail "nonexistent config error is unclear"

touch "${tmp_dir}/config with spaces.json"
ENTRYPOINT_ARGS_FILE="${tmp_dir}/server.args" PATH="${tmp_dir}/bin:${PATH}" \
  HISIM_CONFIG_PATH="${tmp_dir}/config with spaces.json" MODEL_PATH='model with spaces' \
  HOST=127.0.0.1 PORT=31000 "${entrypoint}" server --extra 'value with spaces' \
  >"${tmp_dir}/server.out"
expected_server_args="$(cat <<EOF
-m
hisim.simulation.sglang.launch_server
--model-path
model with spaces
--sim-config-path
${tmp_dir}/config with spaces.json
--host
127.0.0.1
--port
31000
--device
cpu
--skip-server-warmup
--extra
value with spaces
EOF
)"
test "$(cat "${tmp_dir}/server.args")" = "${expected_server_args}" || fail "server arguments are incorrect or not safely quoted"
grep -Fq "model=model with spaces config=${tmp_dir}/config with spaces.json host=127.0.0.1 port=31000" "${tmp_dir}/server.out" || fail "server does not print resolved non-secret settings"

ENTRYPOINT_ARGS_FILE="${tmp_dir}/bench.args" PATH="${tmp_dir}/bin:${PATH}" \
  "${entrypoint}" bench --num-prompts 2
test "$(cat "${tmp_dir}/bench.args")" = "$(printf '%s\n' -m hisim.simulation.bench_serving --bench-mode simulation --warmup-requests 0 --num-prompts 2)" \
  || fail "bench does not force simulation mode and zero warmups"

test "$("${entrypoint}" shell -c 'printf shell-ok')" = shell-ok || fail "shell command is not delegated to Bash"
test "$("${entrypoint}" printf '%s' direct-ok)" = direct-ok || fail "unknown commands are not executed directly"

echo "test_dockerfile.sh: PASS"
