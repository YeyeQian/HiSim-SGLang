#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

docker() {
  printf '/tmp\n'
}

df() {
  printf '%s\n' \
    'Filesystem 1024-blocks Used Available Capacity Mounted on' \
    'fixture 100000000 0 100000000 0% /tmp'
}

git() {
  if [[ "$*" = *third_party/tair-kvcache* ]]; then
    printf '%s\n' 'a6e5d176c96009ba76c0ebb70e83cfb113fe9e65'
  else
    printf '%s\n' '5c8bd8b51b53b9b39eb1edec582ee43b21002106'
  fi
}

ss() {
  if [[ "$*" = *17897* ]]; then
    printf '%s\n' 'LISTEN 0 128 127.0.0.1:17897 0.0.0.0:*'
  fi
}

curl() {
  printf '%s\n' "$*" >>"${TEST_CURL_LOG}"
  [[ "$*" = *http://proxy.example.test:3128* ]]
}

uname() {
  case "${1:-}" in
    -s) printf '%s\n' "${TEST_UNAME_SYSTEM:-Linux}" ;;
    *) printf '%s\n' "${TEST_UNAME_MACHINE:-x86_64}" ;;
  esac
}

command() {
  if [[ "${1:-}" = -v ]]; then
    printf '%s\n' "${2:-}" >>"${TEST_COMMAND_LOG}"
    if [[ "${TEST_HIDE_ARCHIVE_TOOLS:-0}" = 1 ]]; then
      case "${2:-}" in
        sha256sum | unzip) return 1 ;;
      esac
    fi
    if [[ "${TEST_HIDE_CURL:-0}" = 1 && "${2:-}" = curl ]]; then
      return 1
    fi
  fi
  builtin command "$@"
}

export -f command curl docker df git ss uname

curl_log="$(mktemp)"
command_log="$(mktemp)"
trap 'rm -f "${curl_log}" "${command_log}"' EXIT
export TEST_CURL_LOG="${curl_log}"
export TEST_COMMAND_LOG="${command_log}"

for proxy_setting in unset empty direct; do
  : >"${curl_log}"
  case "${proxy_setting}" in
    unset) preflight_output="$(env -u DOCKER_PROJECT_PROXY TEST_HIDE_ARCHIVE_TOOLS=1 TEST_CURL_LOG="${curl_log}" bash "${repo_root}/scripts/preflight.sh")" ;;
    empty) preflight_output="$(TEST_HIDE_ARCHIVE_TOOLS=1 DOCKER_PROJECT_PROXY= bash "${repo_root}/scripts/preflight.sh")" ;;
    direct) preflight_output="$(TEST_HIDE_ARCHIVE_TOOLS=1 DOCKER_PROJECT_PROXY=direct bash "${repo_root}/scripts/preflight.sh")" ;;
  esac
  grep -q 'network mode is direct' <<<"${preflight_output}"
  test ! -s "${curl_log}"
done

if grep -Eq '^(sha256sum|unzip)$' "${command_log}"; then
  echo 'direct generic preflight required an archive-only tool' >&2
  exit 1
fi

grep -Fxq curl "${command_log}" || {
  echo 'direct generic preflight did not require host curl' >&2
  exit 1
}
output="$(TEST_HIDE_CURL=1 DOCKER_PROJECT_PROXY=direct \
  bash "${repo_root}/scripts/preflight.sh" 2>&1)" && {
  echo 'preflight accepted a host without curl' >&2
  exit 1
}
grep -q "required command 'curl' was not found" <<<"${output}"
echo 'generic host curl requirement: PASS'

output="$(TEST_HIDE_ARCHIVE_TOOLS=1 TEST_UNAME_MACHINE=aarch64 DOCKER_PROJECT_PROXY=direct \
  bash "${repo_root}/scripts/preflight.sh" 2>&1)" && {
  echo 'preflight accepted an unsupported non-x86_64 host' >&2
  exit 1
}
grep -q 'requires Linux x86_64' <<<"${output}"
echo 'unsupported architecture rejection: PASS'

output="$(TEST_HIDE_ARCHIVE_TOOLS=1 TEST_UNAME_SYSTEM=Darwin DOCKER_PROJECT_PROXY=direct \
  bash "${repo_root}/scripts/preflight.sh" 2>&1)" && {
  echo 'preflight accepted a non-Linux host' >&2
  exit 1
}
grep -q 'requires Linux x86_64' <<<"${output}"
echo 'unsupported operating system rejection: PASS'

preflight_output="$(DOCKER_PROJECT_PROXY=http://proxy.example.test:3128 \
  bash "${repo_root}/scripts/preflight.sh")"
grep -q 'network mode uses proxy http://proxy.example.test:3128' <<<"${preflight_output}"
grep -F -- '--proxy http://proxy.example.test:3128' "${curl_log}" >/dev/null
echo "valid non-loopback proxy override: PASS"

# A listener on the requested port must not make an unrelated hostname valid.
output="$(
  DOCKER_PROJECT_PROXY=http://definitely-not-a-real-proxy.invalid:17897 \
    bash "${repo_root}/scripts/preflight.sh" 2>&1
)" && {
  echo "preflight accepted an unreachable proxy endpoint" >&2
  exit 1
}
grep -q "proxy endpoint definitely-not-a-real-proxy.invalid:17897 is not reachable" <<<"${output}"
echo "invalid non-loopback proxy endpoint: PASS"

echo "test_preflight.sh: PASS"
