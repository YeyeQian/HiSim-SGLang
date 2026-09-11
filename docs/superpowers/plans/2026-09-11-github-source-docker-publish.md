# GitHub Source + Docker Publication Implementation Plan

> **For Codex:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development to implement this plan task-by-task.

**Goal:** Publish a portable source-built Docker workflow to the new GitHub repository and make the generic CPU-only probe runnable with minimal target-host setup.

**Architecture:** Keep all project/runtime dependencies inside the existing Docker image. Add one shared direct/proxy network selector used by build, downloads, and metadata preparation, then compose existing lifecycle scripts behind a fail-safe quickstart entrypoint. Preserve the pinned submodules and current simulation semantics.

**Tech Stack:** Bash, Docker, Python unittest, Git submodules, Markdown

**Spec:** `docs/superpowers/specs/2026-09-11-github-source-docker-publish-design.md`

## Global Constraints

- Never add `third_party/llm-ep-simulator/`, `.local_docs/`, data, caches, results, logs, Docker images, `.worktrees/`, or credentials to Git.
- The user explicitly authorized deleting `.worktrees/cpu-docker-smoke`; retain its feature branch and retain every newly created worktree/branch unless the user separately authorizes deletion.
- Keep SGLang `0.5.6.post2`, Qwen3-8B, HiSim paths, CPU-only guards, loopback binding, fixed-port failure semantics, and benchmark lifecycle semantics unchanged.
- Project dependencies remain inside Docker; do not add host Python/CUDA/NVIDIA installation steps.
- Use test-first implementation for behavioral changes and retain offline fake-command tests.
- Push only `main` to `https://github.com/YeyeQian/HiSim-SGLang.git` after final verification and content audit.

### Task 1: Preserve and baseline the already-requested documentation organization

**Files:**
- Commit: `dev_docs/simulation/**/*.md`
- Modify: `.gitignore`
- Delete from Git and preserve locally: `docker_network_and_proxy_troubleshooting_guide.md` -> `.local_docs/docker_network_and_proxy_troubleshooting_guide.md`
- Create: `docs/superpowers/specs/2026-09-11-github-source-docker-publish-design.md`
- Create: `docs/superpowers/plans/2026-09-11-github-source-docker-publish.md`

**Step 1: Audit the pending paths**

Run `git status --short`, `git diff --check`, and inspect every pending path. Confirm no generated artifact or `third_party/llm-ep-simulator/` is staged.

**Step 2: Commit the baseline**

Stage only the listed documentation/spec/plan paths and commit them. Do not stage with an unbounded `git add -A`.

**Step 3: Create the isolated feature worktree**

Verify `.worktrees/` is ignored. Create `.worktrees/github-source-docker-publish` on branch `feature/github-source-docker-publish`, and retain it after completion.

### Task 2: Make direct networking the portable default

**Files:**
- Modify: `scripts/lib/common.sh`
- Modify: `scripts/preflight.sh`
- Modify: `scripts/build.sh`
- Modify: `scripts/fetch_h20_data.sh`
- Modify: `scripts/fetch_sharegpt_data.sh`
- Modify: `scripts/start_server.sh`
- Modify: `tests/test_common.sh`
- Modify: `tests/test_preflight.sh`
- Modify: `tests/test_build_scripts.sh`
- Modify: `tests/test_fetch_h20_data.sh`
- Modify: `tests/test_fetch_sharegpt_data.sh`
- Modify: `tests/test_lifecycle_scripts.sh`

**Step 1: Write failing tests**

Cover unset, empty, and explicit `direct` direct mode plus explicit HTTP proxy preservation. Assert direct mode omits curl proxy arguments, Docker build proxy build args, and metadata proxy environment variables. Keep an explicit loopback proxy usable on the current server, but do not auto-detect it.

**Step 2: Run the focused tests to prove failure**

Run the modified shell test files and record the expected failures.

**Step 3: Implement the smallest shared selector**

Put mode resolution and reusable optional argument helpers in `scripts/lib/common.sh`. Make preflight report direct mode or validate an explicit proxy. Update all consumers without changing their timeout, retry, checksum, ownership, or lifecycle behavior.

**Step 4: Run focused and aggregate tests**

Run the modified shell tests, then `bash scripts/test_all.sh`.

**Step 5: Commit**

Commit the tested network portability change with a focused message.

### Task 3: Add Docker-based validation and an end-to-end generic quickstart

**Files:**
- Create: `scripts/quickstart.sh`
- Create: `scripts/validate_results.sh`
- Create: `tests/test_quickstart.sh`
- Create: `tests/test_validate_results_wrapper.sh`
- Modify: `scripts/test_all.sh`

**Step 1: Write the failing orchestration test**

Use temporary fixtures and fake Docker/child scripts. First assert that the validation wrapper runs `validate_results.py` inside the built image with only the required read-only/read-write mounts. Then assert the quickstart order: submodule/pin validation, preflight, build, image inspection, generic start, readiness, probe benchmark, Docker-based result validation, and stop. Cover a mid-flow failure and prove cleanup runs only after this quickstart successfully started its project service.

**Step 2: Run the test to prove failure**

Run `bash tests/test_quickstart.sh` and record that the missing script/behavior fails.

**Step 3: Implement the orchestration script**

Compose existing scripts rather than duplicate their logic. Keep the default path generic `random-ids`; do not fetch H20, ShareGPT, or full model weights. Preserve evidence directories and return the first failing status after safe cleanup.

**Step 4: Integrate and verify**

Add the test to `scripts/test_all.sh`; run the focused test and aggregate suite.

**Step 5: Commit**

Commit the quickstart and its tests.

### Task 4: Make the source build and GitHub handoff self-contained and safe

**Files:**
- Modify: `.gitignore`
- Create: `.dockerignore`
- Modify: `Dockerfile`
- Modify: `configs/versions.env`
- Modify: `scripts/preflight.sh`
- Modify: `tests/test_preflight.sh`
- Modify: `README.md`
- Delete from public Git and preserve under root `.local_docs/`: `HISIM_SGLANG_CPU_DOCKER_HANDOFF.md`
- Delete from public Git and preserve under root `.local_docs/`: `dev_docs/init_pj/hisim_sglang_cpu_docker_confirmed_plan.md`
- Modify: `docs/superpowers/plans/2026-09-08-hisim-sglang-cpu-docker.md`
- Modify: `dev_docs/simulation/**/*.md`
- Create: `dev_docs/simulation/README.md`
- Create: `tests/test_repo_hygiene.sh`
- Modify: `scripts/test_all.sh`

**Step 1: Write failing hygiene/link tests**

Assert `third_party/llm-ep-simulator/`, `.local_docs/`, the two current-server-only development documents, and generated paths are excluded from Git and Docker build context; required submodules remain gitlinks; no tracked file exceeds the chosen source-release threshold; the AIConfigurator fixed commit can be fetched independently of a moving branch tip; the ShareGPT URL uses its declared revision; generic preflight rejects non-x86_64 while not requiring H20-only archive tools; and local Markdown links in public documentation resolve without referring to removed local-only documents.

**Step 2: Run tests to prove the current gaps**

Run the new hygiene test and capture the expected ignore/link failures.

**Step 3: Update public documentation and ignore rules**

Add `.dockerignore`, make AIConfigurator fixed-commit retrieval independent of the current branch tip, and use the pinned ShareGPT revision in its URL. Make generic preflight require only tools used by the generic path and reject unsupported non-x86_64 hosts; H20/ShareGPT download scripts keep checking their own extra tools. Add a first-screen GitHub clone + quickstart path, Linux x86_64 target-host requirements, direct-by-default behavior, an explicit proxy override for the current server, resource expectations, the source-build limitation, and manual lifecycle commands. Add a navigation index and repair paths broken by the prior documentation move. Remove the two server-specific development documents from public Git, remove or rewrite inbound public references, and preserve their byte-identical copies in the root checkout's ignored `.local_docs/`. Put the local reference checkout and local-only documents in versioned ignore rules.

**Step 4: Verify**

Run the hygiene test, aggregate suite, Markdown link checks, and `git diff --check`.

**Step 5: Commit**

Commit the handoff documentation and repository hygiene safeguards.

### Task 5: Final review, merge locally, and publish `main`

**Files:**
- Verify: entire repository
- Git metadata: add/update `origin`

**Step 1: Run final verification**

Run all shell and Python tests, syntax checks, `git diff --check`, submodule pin checks, tracked-file size/type audits, ignored-file checks, and secret-pattern scans. Confirm both the root worktree and feature worktree are in the expected state.

**Step 2: Obtain independent whole-branch review**

Review the complete feature diff against the design and all deferred findings. Address load-bearing findings through the subagent fix/re-review workflow.

**Step 3: Merge locally without deleting the branch/worktree**

Merge `feature/github-source-docker-publish` into local `main`. Do not delete the branch or `.worktrees/github-source-docker-publish`.

**Step 4: Re-verify the exact main commit**

Repeat the release-critical tests and content audit on `main`.

**Step 5: Configure and push**

Set `origin` to `https://github.com/YeyeQian/HiSim-SGLang.git` if absent, verify it, and push only `main`. If GitHub authentication is unavailable, stop and report the exact non-destructive authentication step needed; do not expose or persist credentials in the repository.
