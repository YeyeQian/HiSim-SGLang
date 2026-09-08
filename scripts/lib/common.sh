#!/usr/bin/env bash

project_root() {
  cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P
}

proxy_url() {
  printf '%s\n' "${DOCKER_PROJECT_PROXY:-http://127.0.0.1:17897}"
}

die() {
  printf 'ERROR: %s\n' "$*" >&2
  return 1
}

require_command() {
  command -v "$1" >/dev/null 2>&1 ||
    die "required command '$1' was not found; install it and retry"
}

require_free_port() {
  local port="$1"

  [[ "${port}" =~ ^[0-9]+$ ]] || die "invalid port '${port}'"
  if ss -ltnH "sport = :${port}" | grep -q .; then
    die "port ${port} is already in use; stop its listener or select another port"
  fi
}
