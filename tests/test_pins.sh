#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# shellcheck source=/dev/null
source "${repo_root}/configs/versions.env"

test "${TAIR_KVCACHE_COMMIT}" = "a6e5d176c96009ba76c0ebb70e83cfb113fe9e65"
test "${SGLANG_COMMIT}" = "5c8bd8b51b53b9b39eb1edec582ee43b21002106"
test "${SGLANG_VERSION}" = "0.5.6.post2"
test "${AICONFIGURATOR_COMMIT}" = "9f744a1910f317a091c88ade644d61094ea22119"
test "${LATENCY_PRISM_COMMIT}" = "d242ca5b8d7217e1d235d2fb225ff4a8ba24995a"
test "${H20_AIC_SHA256}" = "7702dbffe750a9d0f6b7ce547056bfbaa3da5e158ac7fa25e75b057df4792289"
test "${SHAREGPT_REVISION}" = "192ab2185289094fc556ec8ce5ce1e8e587154ca"
test "${SHAREGPT_URL}" = "https://huggingface.co/datasets/anon8231489123/ShareGPT_Vicuna_unfiltered/resolve/${SHAREGPT_REVISION}/ShareGPT_V3_unfiltered_cleaned_split.json"
test "${SHAREGPT_SIZE}" = "672837942"
test "${SHAREGPT_SHA256}" = "35f0e213ce091ed9b9af2a1f0755e9d39f9ccec34ab281cd4ca60d70f6479ba4"
test "${UBUNTU_2204_IMAGE}" = "ubuntu:22.04@sha256:3b06811b2afd352be909dd088a004166d665dc76d38b13eada33522a9d915c6f"

test "$(git -C "${repo_root}/third_party/tair-kvcache" rev-parse HEAD)" = "${TAIR_KVCACHE_COMMIT}"
test "$(git -C "${repo_root}/third_party/sglang" rev-parse HEAD)" = "${SGLANG_COMMIT}"
test "$(sed -n '1p' "${repo_root}/configs/assets.sha256")" = "${H20_AIC_SHA256}  H20_AIC.zip"
test "$(sed -n '2p' "${repo_root}/configs/assets.sha256")" = "${SHAREGPT_SHA256}  ShareGPT_V3_unfiltered_cleaned_split.json"
