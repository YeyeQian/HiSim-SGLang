#!/usr/bin/env bash
set -euo pipefail

reject_conflicting_option() {
  local option="$1"
  local required_value="$2"
  local argument
  local supplied_value
  shift 2

  while (($# > 0)); do
    argument="$1"
    shift
    case "${argument}" in
      "${option}")
        if (($# == 0)); then
          echo "entrypoint: ${option} conflicts with required value ${required_value}: no value supplied" >&2
          exit 64
        fi
        supplied_value="$1"
        shift
        ;;
      "${option}="*)
        supplied_value="${argument#*=}"
        ;;
      *)
        continue
        ;;
    esac

    if [[ "${supplied_value}" != "${required_value}" ]]; then
      echo "entrypoint: ${option}=${supplied_value} conflicts with required value ${required_value}" >&2
      exit 64
    fi
  done
}

command_name="${1:-server}"

case "${command_name}" in
  server)
    if (($# > 0)); then
      shift
    fi
    model_path="${MODEL_PATH:-Qwen/Qwen3-8B}"
    config_path="${HISIM_CONFIG_PATH:-}"
    host="${HOST:-0.0.0.0}"
    port="${PORT:-30000}"

    reject_conflicting_option --device cpu "$@"

    if [[ -z "${config_path}" ]]; then
      echo "entrypoint: HISIM_CONFIG_PATH is required for server" >&2
      exit 64
    fi
    if [[ ! -f "${config_path}" ]]; then
      echo "entrypoint: HISIM_CONFIG_PATH does not exist: ${config_path}" >&2
      exit 66
    fi

    printf 'Starting HiSim server: model=%s config=%s host=%s port=%s\n' \
      "${model_path}" "${config_path}" "${host}" "${port}"
    exec python -m hisim.simulation.sglang.launch_server \
      "$@" \
      --model-path "${model_path}" \
      --sim-config-path "${config_path}" \
      --host "${host}" \
      --port "${port}" \
      --device cpu \
      --skip-server-warmup
    ;;
  bench)
    shift
    reject_conflicting_option --bench-mode simulation "$@"
    reject_conflicting_option --warmup-requests 0 "$@"
    exec python -m hisim.simulation.bench_serving \
      "$@" \
      --bench-mode simulation \
      --warmup-requests 0
    ;;
  versions)
    shift
    exec python - <<'PY'
import importlib
import importlib.metadata
import platform
import sys

import torch


def package_version(distribution, module_name=None):
    try:
        return importlib.metadata.version(distribution)
    except importlib.metadata.PackageNotFoundError:
        if module_name is None:
            return "unavailable"
        try:
            module = importlib.import_module(module_name)
        except ImportError:
            return "unavailable"
        return getattr(module, "__version__", "unknown")


print(f"Python: {platform.python_version()} ({sys.executable})")
print(f"torch: {package_version('torch', 'torch')}")
print(f"SGLang: {package_version('sglang', 'sglang')}")
print(f"HiSim: {package_version('hisim', 'hisim')}")
print(f"AIConfigurator: {package_version('aiconfigurator', 'aiconfigurator')}")
print(f"torch.cuda.is_available(): {torch.cuda.is_available()}")
print(f"platform: {platform.platform()}")
PY
    ;;
  shell)
    shift
    exec /bin/bash "$@"
    ;;
  *)
    exec "$@"
    ;;
esac
