#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "${script_dir}/lib/common.sh"

kind="${1:-}"
[[ $# -eq 1 && ( "${kind}" = generic || "${kind}" = h20 ) ]] ||
  die "usage: $0 generic|h20"

repo_root="$(project_root)"
image="${HISIM_IMAGE:-hisim-sglang-cpu:0.5.6.post2}"
container_name="${HISIM_CONTAINER_NAME:-hisim-sglang-cpu-smoke}"
port="${HISIM_PORT:-30000}"
results_root="${RESULTS_ROOT:-${repo_root}/results}"
cache_dir="${HF_CACHE_DIR:-${repo_root}/cache/huggingface}"
state_dir="${results_root}/.state/${container_name}"
metadata_timeout="${MODEL_METADATA_TIMEOUT_SECONDS:-300}"
[[ "${metadata_timeout}" =~ ^[1-9][0-9]*$ ]] ||
  die "model metadata timeout must be a positive integer"

case "${kind}" in
  generic)
    config_path="${repo_root}/third_party/tair-kvcache/hisim/test/assets/mock/config.json"
    ;;
  h20)
    config_path="${repo_root}/configs/h20-qwen3-8b.json"
    h20_data_dir="${repo_root}/artifacts/h20_aic/aic"
    [[ -d "${h20_data_dir}" ]] || die "H20 data is missing at ${h20_data_dir}; run scripts/fetch_h20_data.sh first"
    ;;
esac
[[ -f "${config_path}" ]] || die "${kind} config is missing at ${config_path}"

HISIM_PORT="${port}" bash "${repo_root}/scripts/preflight.sh"
if docker container inspect "${container_name}" >/dev/null 2>&1; then
  die "container ${container_name} already exists; stop it explicitly before retrying"
fi

run_id="$(date -u +%Y%m%dT%H%M%SZ)-${kind}-$$"
run_dir="${results_root}/${run_id}"
server_dir="${run_dir}/server/${kind}"
mkdir -p "${cache_dir}" "${server_dir}" "${state_dir}"
# Keep the image's fixed non-root app identity. Only the two project-owned bind
# roots are made writable so UID 10001 can create cache and result artifacts.
runtime_uid=10001
runtime_gid=10001
chmod 0777 "${cache_dir}" "${run_dir}"
du -sk -- "${cache_dir}" >"${server_dir}/cache-before.txt"

# Download only public model configuration and tokenizer assets while host
# networking can reach the host-loopback proxy. The serving container remains
# bridge-networked and uses this cache offline; no model class is instantiated.
proxy="$(proxy_url)"
metadata_code='from transformers import AutoConfig, AutoTokenizer; model="Qwen/Qwen3-8B"; AutoConfig.from_pretrained(model); AutoTokenizer.from_pretrained(model)'
metadata_args=(
  run --rm
  --name "${container_name}"
  --network host
  --user "${runtime_uid}:${runtime_gid}"
  --env "HTTP_PROXY=${proxy}"
  --env "HTTPS_PROXY=${proxy}"
  --env "http_proxy=${proxy}"
  --env "https_proxy=${proxy}"
  --volume "${cache_dir}:/home/app/.cache/huggingface:rw"
  "${image}" shell -c "python -c '${metadata_code}'"
)
printf '%q ' timeout "${metadata_timeout}s" docker "${metadata_args[@]}" >"${server_dir}/metadata-command.txt"
printf '\n' >>"${server_dir}/metadata-command.txt"
set +e
timeout "${metadata_timeout}s" docker "${metadata_args[@]}" \
  >"${server_dir}/metadata.stdout.log" 2>"${server_dir}/metadata.stderr.log"
metadata_status=$?
set -e
printf '%s\n' "${metadata_status}" >"${server_dir}/metadata.exit-code.txt"
du -sk -- "${cache_dir}" >"${server_dir}/cache-after-metadata.txt"
[[ "${metadata_status}" -eq 0 ]] ||
  die "model config/tokenizer preparation failed with status ${metadata_status}; see ${server_dir}/metadata.stderr.log"

docker_args=(
  run --detach
  --name "${container_name}"
  --cpus 16
  --memory 32g
  --shm-size 4g
  --network bridge
  --publish "127.0.0.1:${port}:30000"
  --user "${runtime_uid}:${runtime_gid}"
  --env HISIM_CONFIG_PATH=/run/hisim/config.json
  --env MODEL_PATH=Qwen/Qwen3-8B
  --env HOST=0.0.0.0
  --env PORT=30000
  --env HF_HUB_OFFLINE=1
  --env TRANSFORMERS_OFFLINE=1
  --volume "${repo_root}/third_party/tair-kvcache:/workspace/tair-kvcache:ro"
  --volume "${config_path}:/run/hisim/config.json:ro"
  --volume "${cache_dir}:/home/app/.cache/huggingface:rw"
  --volume "${run_dir}:/results:rw"
)
if [[ "${kind}" = h20 ]]; then
  docker_args+=(--volume "${h20_data_dir}:/opt/hisim-data/aic:ro")
fi
docker_args+=("${image}" server)

{
  printf 'run_id=%q\n' "${run_id}"
  printf 'kind=%q\n' "${kind}"
  printf 'image=%q\n' "${image}"
  printf 'container_name=%q\n' "${container_name}"
  printf 'host_port=%q\n' "${port}"
  printf 'started_at=%q\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  printf 'config_path=%q\n' "${config_path}"
  printf 'command='; printf '%q ' docker "${docker_args[@]}"; printf '\n'
} >"${server_dir}/launch.env"

container_id="$(docker "${docker_args[@]}")"
[[ -n "${container_id}" ]] || die "Docker did not return a container ID"
printf '%s\n' "${container_id}" >"${state_dir}/container_id"
printf '%s\n' "${container_name}" >"${state_dir}/container_name"
printf '%s\n' "${kind}" >"${state_dir}/kind"
printf '%s\n' "${run_dir}" >"${state_dir}/run_dir"

# This follows server output from the first moment after launch. The pinned
# SGLang weight messages are intentionally included; metadata/tokenizer fetches
# are not guard conditions.
guard_pattern='Load weight begin[.]|Load weight end[.]|Loading checkpoint shards|Loading safetensors checkpoint|Loading model weights|Weights loaded into memory|Executing real model forward|ModelRunner[.]forward|Forward pass started|CUDA (runtime )?initialized|Initializing CUDA|torch[.]cuda[.]init|NCCL communicator'
guard_log="${server_dir}/runtime-guard.log"
guard_failure="${server_dir}/runtime-guard-failure.txt"
: >"${guard_log}"
(
  docker logs --follow "${container_id}" 2>&1 | while IFS= read -r log_line; do
    printf '%s\n' "${log_line}" >>"${guard_log}"
    if printf '%s\n' "${log_line}" | grep -E "${guard_pattern}" >/dev/null; then
      printf 'Forbidden runtime indicator: %s\n' "${log_line}" >"${guard_failure}"
      bash "${repo_root}/scripts/stop_server.sh" >/dev/null 2>&1 || true
      exit 90
    fi
  done
) </dev/null >/dev/null 2>&1 &

printf 'Started %s as %s (%s); evidence: %s\n' \
  "${kind}" "${container_name}" "${container_id}" "${server_dir}"
