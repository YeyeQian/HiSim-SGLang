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
  [[ "$*" = *http://proxy.example.test:3128* ]]
}

export -f curl docker df git ss

DOCKER_PROJECT_PROXY=http://proxy.example.test:3128 \
  bash "${repo_root}/scripts/preflight.sh" >/dev/null
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
