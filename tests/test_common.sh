#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
common="${repo_root}/scripts/lib/common.sh"

# shellcheck source=/dev/null
source "${common}"

test "$(project_root)" = "${repo_root}"
test "$(env -u DOCKER_PROJECT_PROXY bash -c 'source "$1"; network_mode' _ "${common}")" = direct
test "$(DOCKER_PROJECT_PROXY= network_mode)" = direct
test "$(DOCKER_PROJECT_PROXY=direct network_mode)" = direct
test "$(DOCKER_PROJECT_PROXY=http://127.0.0.1:12345 network_mode)" = proxy
test "$(DOCKER_PROJECT_PROXY=http://127.0.0.1:12345 proxy_url)" = "http://127.0.0.1:12345"

for proxy_setting in unset empty direct; do
  proxy_args=(sentinel)
  build_args=(sentinel)
  env_args=(sentinel)
  case "${proxy_setting}" in
    unset) unset DOCKER_PROJECT_PROXY ;;
    empty) DOCKER_PROJECT_PROXY= ;;
    direct) DOCKER_PROJECT_PROXY=direct ;;
  esac
  append_curl_proxy_args proxy_args
  append_docker_build_proxy_args build_args
  append_docker_proxy_env_args env_args
  test "${proxy_args[*]}" = sentinel
  test "${build_args[*]}" = sentinel
  test "${env_args[*]}" = sentinel
done

DOCKER_PROJECT_PROXY=http://proxy.example.test:3128
proxy_args=()
build_args=()
env_args=()
append_curl_proxy_args proxy_args
append_docker_build_proxy_args build_args
append_docker_proxy_env_args env_args
test "${proxy_args[*]}" = '--proxy http://proxy.example.test:3128'
test "${build_args[*]}" = '--build-arg HTTP_PROXY=http://proxy.example.test:3128 --build-arg HTTPS_PROXY=http://proxy.example.test:3128 --build-arg http_proxy=http://proxy.example.test:3128 --build-arg https_proxy=http://proxy.example.test:3128'
test "${env_args[*]}" = '--env HTTP_PROXY=http://proxy.example.test:3128 --env HTTPS_PROXY=http://proxy.example.test:3128 --env http_proxy=http://proxy.example.test:3128 --env https_proxy=http://proxy.example.test:3128'
unset DOCKER_PROJECT_PROXY

require_command sh
missing_output="$(require_command definitely-not-a-real-command 2>&1 || true)"
grep -q 'definitely-not-a-real-command' <<<"${missing_output}"
if require_command definitely-not-a-real-command >/dev/null 2>&1; then
  echo "require_command accepted a missing command" >&2
  exit 1
fi

tmp_dir="$(mktemp -d)"
listener_pid=""
cleanup() {
  if [[ -n "${listener_pid}" ]]; then
    kill "${listener_pid}" 2>/dev/null || true
    wait "${listener_pid}" 2>/dev/null || true
  fi
  rm -rf "${tmp_dir}"
}
trap cleanup EXIT

free_port="$(python3 - <<'PY'
import socket
with socket.socket() as sock:
    sock.bind(("127.0.0.1", 0))
    print(sock.getsockname()[1])
PY
)"
require_free_port "${free_port}"

python3 - "${tmp_dir}/port" <<'PY' &
import socket
import sys

with socket.socket() as sock:
    sock.bind(("127.0.0.1", 0))
    sock.listen()
    with open(sys.argv[1], "w", encoding="utf-8") as output:
        output.write(str(sock.getsockname()[1]))
    sock.accept()
PY
listener_pid=$!

for _ in {1..50}; do
  [[ -s "${tmp_dir}/port" ]] && break
  sleep 0.02
done
occupied_port="$(cat "${tmp_dir}/port")"
if require_free_port "${occupied_port}" >/dev/null 2>&1; then
  echo "require_free_port accepted an occupied port" >&2
  exit 1
fi

echo "test_common.sh: PASS"
