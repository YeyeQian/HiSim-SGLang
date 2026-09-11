#!/usr/bin/env bash

project_root() {
  cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P
}

network_mode() {
  local setting="${DOCKER_PROJECT_PROXY-}"
  case "${setting}" in
    '' | direct)
      printf 'direct\n'
      return
      ;;
  esac
  if [[ "${setting}" =~ ^http://[A-Za-z0-9._-]+:[0-9]+/?$ ]]; then
    printf 'proxy\n'
  else
    die "unsupported DOCKER_PROJECT_PROXY '${setting}'; expected direct or http://HOST:PORT"
  fi
}

proxy_url() {
  local mode
  mode="$(network_mode)" || return
  if [[ "${mode}" = proxy ]]; then
    printf '%s\n' "${DOCKER_PROJECT_PROXY}"
  fi
}

append_curl_proxy_args() {
  local destination="$1"
  local mode
  mode="$(network_mode)" || return
  if [[ "${mode}" = proxy ]]; then
    append_array_args "${destination}" --proxy "$(proxy_url)"
  fi
}

append_docker_build_proxy_args() {
  local destination="$1"
  local mode proxy
  mode="$(network_mode)" || return
  if [[ "${mode}" = proxy ]]; then
    proxy="$(proxy_url)"
    append_array_args "${destination}" \
      --build-arg "HTTP_PROXY=${proxy}" \
      --build-arg "HTTPS_PROXY=${proxy}" \
      --build-arg "http_proxy=${proxy}" \
      --build-arg "https_proxy=${proxy}"
  fi
}

append_docker_proxy_env_args() {
  local destination="$1"
  local mode proxy
  mode="$(network_mode)" || return
  if [[ "${mode}" = proxy ]]; then
    proxy="$(proxy_url)"
    append_array_args "${destination}" \
      --env "HTTP_PROXY=${proxy}" \
      --env "HTTPS_PROXY=${proxy}" \
      --env "http_proxy=${proxy}" \
      --env "https_proxy=${proxy}"
  fi
}

append_array_args() {
  local destination="$1"
  local argument quoted
  [[ "${destination}" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || die "invalid array name '${destination}'"
  shift
  for argument in "$@"; do
    printf -v quoted '%q' "${argument}"
    eval "${destination}+=( ${quoted} )"
  done
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
