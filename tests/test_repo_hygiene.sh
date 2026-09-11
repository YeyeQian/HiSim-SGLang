#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${repo_root}"

fail() {
  printf 'test_repo_hygiene.sh: %s\n' "$*" >&2
  exit 1
}

ignored_paths=(
  .local_docs/private.md
  .worktrees/feature-copy/file
  third_party/llm-ep-simulator/README.md
  HISIM_SGLANG_CPU_DOCKER_HANDOFF.md
  dev_docs/init_pj/hisim_sglang_cpu_docker_confirmed_plan.md
  cache/huggingface/config.json
  results/run/metrics.json
  logs/build.log
  artifacts/h20_aic/data.txt
  artifacts/downloads/archive.zip
  artifacts/image/inspect.json
  package/__pycache__/module.cpython-312.pyc
  local.env.local
)

for path in "${ignored_paths[@]}"; do
  git check-ignore --no-index -q -- "${path}" || fail ".gitignore does not exclude ${path}"
done

[[ -f .dockerignore ]] || fail '.dockerignore is missing'
for path in "${ignored_paths[@]}" .git/config third_party/sglang/.git third_party/tair-kvcache/.git .superpowers/private/report.md; do
  python3 - ".dockerignore" "${path}" <<'PYTHON' || fail ".dockerignore does not exclude ${path}"
import fnmatch
import pathlib
import sys

patterns = []
for raw in pathlib.Path(sys.argv[1]).read_text().splitlines():
    line = raw.strip()
    if line and not line.startswith("#") and not line.startswith("!"):
        patterns.append(line.lstrip("/"))
path = sys.argv[2].lstrip("/")

def matches(pattern):
    pattern = pattern.rstrip("/")
    return (
        path == pattern
        or path.startswith(pattern + "/")
        or fnmatch.fnmatch(path, pattern)
    )

raise SystemExit(0 if any(matches(pattern) for pattern in patterns) else 1)
PYTHON
done

for local_only in \
  HISIM_SGLANG_CPU_DOCKER_HANDOFF.md \
  dev_docs/init_pj/hisim_sglang_cpu_docker_confirmed_plan.md; do
  git ls-files --error-unmatch -- "${local_only}" >/dev/null 2>&1 &&
    fail "local-only document remains tracked: ${local_only}"
done

if git ls-files '.superpowers/**' | grep -q .; then
  fail 'generated root .superpowers workspace content remains tracked'
fi

for submodule in third_party/sglang third_party/tair-kvcache; do
  mode="$(git ls-files -s -- "${submodule}" | awk '{print $1}')"
  [[ "${mode}" = 160000 ]] || fail "${submodule} is not a gitlink"
done

max_blob_bytes=$((10 * 1024 * 1024))
while read -r mode object stage path; do
  [[ "${mode}" = 160000 ]] && continue
  size="$(git cat-file -s "${object}")"
  ((size <= max_blob_bytes)) || fail "tracked file exceeds 10 MiB: ${path} (${size} bytes)"
done < <(git ls-files -s)

grep -Fq 'timeout 120s env GIT_LFS_SKIP_SMUDGE=1 git -C /opt/src/aiconfigurator fetch --depth 1 origin "${AICONFIGURATOR_COMMIT}"' Dockerfile ||
  fail 'AIConfigurator fixed commit fetch is not directly pinned and bounded to 120 seconds'
if grep -Eq 'git clone .*--branch[ =]' Dockerfile; then
  fail 'AIConfigurator retrieval still depends on a moving branch tip'
fi

# shellcheck source=/dev/null
source configs/versions.env
[[ "${SHAREGPT_URL}" = *"/resolve/${SHAREGPT_REVISION}/"* ]] ||
  fail 'SHAREGPT_URL does not use SHAREGPT_REVISION'

python3 scripts/check_markdown_links.py "${repo_root}" ||
  fail 'public Markdown contains a broken or unpublished local link'

tmp_dir="$(mktemp -d)"
trap 'rm -rf -- "${tmp_dir}"' EXIT
git -C "${tmp_dir}" init -q
git -C "${tmp_dir}" config user.email test@example.invalid
git -C "${tmp_dir}" config user.name 'Hygiene Test'

printf '%s\n' '[published][guide]' '' '[guide]: guide.md' >"${tmp_dir}/README.md"
printf '%s\n' '# Guide' >"${tmp_dir}/guide.md"
printf '%s\n' 'ignored.md' >"${tmp_dir}/.gitignore"
git -C "${tmp_dir}" add .gitignore README.md guide.md
python3 scripts/check_markdown_links.py "${tmp_dir}" ||
  fail 'reference-style link to a tracked file was rejected'

printf '%s\n' '[private](ignored.md)' >"${tmp_dir}/README.md"
printf '%s\n' 'local only' >"${tmp_dir}/ignored.md"
if python3 scripts/check_markdown_links.py "${tmp_dir}" >/dev/null 2>&1; then
  fail 'link gate accepted an existing but untracked local target'
fi

printf '%s\n' '[missing][guide]' '' '[guide]: absent.md' >"${tmp_dir}/README.md"
if python3 scripts/check_markdown_links.py "${tmp_dir}" >/dev/null 2>&1; then
  fail 'link gate ignored a broken reference-style local link'
fi

echo 'test_repo_hygiene.sh: PASS'
