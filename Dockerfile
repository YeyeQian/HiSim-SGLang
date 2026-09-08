FROM ubuntu:22.04@sha256:3b06811b2afd352be909dd088a004166d665dc76d38b13eada33522a9d915c6f

SHELL ["/bin/bash", "-o", "pipefail", "-c"]

ARG AICONFIGURATOR_COMMIT=9f744a1910f317a091c88ade644d61094ea22119

ENV PATH="/opt/venv/bin:${PATH}" \
    SGLANG_USE_CPU_ENGINE=1 \
    FLASHINFER_DISABLE_VERSION_CHECK=1 \
    PYTHONUNBUFFERED=1 \
    PIP_NO_CACHE_DIR=1 \
    XDG_CACHE_HOME=/home/app/.cache \
    HF_HOME=/home/app/.cache/huggingface

RUN apt-get update \
    && DEBIAN_FRONTEND=noninteractive apt-get install --no-install-recommends -y \
        build-essential \
        ca-certificates \
        cmake \
        git \
        google-perftools \
        libnuma-dev \
        libtbb-dev \
        ninja-build \
        numactl \
        python3 \
        python3-dev \
        python3-pip \
        python3-venv \
    && python3 -m venv /opt/venv \
    && rm -rf /var/lib/apt/lists/*

RUN python -m pip install --upgrade pip setuptools wheel scikit-build-core \
    && python -m pip install \
        --index-url https://download.pytorch.org/whl/cpu \
        torch==2.9.0 \
        torchvision==0.24.0 \
        triton==3.5.0

COPY third_party/sglang /opt/src/sglang
COPY configs/requirements.cpu.txt /tmp/requirements.cpu.txt
COPY patches/sglang/2f4a6add-cpu-fallbacks.patch /tmp/sglang-cpu.patch

WORKDIR /opt/src
RUN git apply --check --no-index --directory=sglang /tmp/sglang-cpu.patch \
    && git apply --no-index --directory=sglang /tmp/sglang-cpu.patch

WORKDIR /opt/src/sglang
RUN cp python/pyproject_cpu.toml python/pyproject.toml \
    && python -m pip install --constraint /tmp/requirements.cpu.txt ./python \
    && cp sgl-kernel/pyproject_cpu.toml sgl-kernel/pyproject.toml \
    && python -m pip install --no-build-isolation ./sgl-kernel

COPY third_party/tair-kvcache/hisim /opt/src/hisim

RUN python -m pip install --constraint /tmp/requirements.cpu.txt numpy scikit-learn xgboost

WORKDIR /
ARG GIT_LFS_VERSION=3.7.1
ARG GIT_LFS_SHA256=1c0b6ee5200ca708c5cebebb18fdeb0e1c98f1af5c1a9cba205a4c0ab5a5ec08

RUN for attempt in 1 2 3; do \
      rm -f /tmp/git-lfs.tar.gz; \
      timeout 60s python -c "import urllib.request; urllib.request.urlretrieve('https://github.com/git-lfs/git-lfs/releases/download/v${GIT_LFS_VERSION}/git-lfs-linux-amd64-v${GIT_LFS_VERSION}.tar.gz', '/tmp/git-lfs.tar.gz')" \
        && break; \
      test "${attempt}" -lt 3 || exit 1; \
    done \
    && printf '%s  %s\n' "${GIT_LFS_SHA256}" /tmp/git-lfs.tar.gz | sha256sum --check \
    && tar -xzf /tmp/git-lfs.tar.gz -C /tmp \
    && install -m 0755 "/tmp/git-lfs-${GIT_LFS_VERSION}/git-lfs" /usr/local/bin/git-lfs \
    && git lfs install --system \
    && git lfs version | grep -F "git-lfs/${GIT_LFS_VERSION}" \
    && rm -f /tmp/git-lfs.tar.gz

RUN for attempt in 1 2 3; do \
      rm -rf /opt/src/aiconfigurator; \
      timeout 120s env GIT_LFS_SKIP_SMUDGE=1 git clone --depth 1 --branch h20e-higher-acc --single-branch --no-checkout \
          https://github.com/ai-dynamo/aiconfigurator.git /opt/src/aiconfigurator \
        && break; \
      test "${attempt}" -lt 3 || exit 1; \
    done \
    && GIT_LFS_SKIP_SMUDGE=1 git -C /opt/src/aiconfigurator checkout --detach "${AICONFIGURATOR_COMMIT}" \
    && for attempt in 1 2 3; do \
      if [ -d /opt/src/aiconfigurator/.git/lfs/incomplete ]; then \
        find /opt/src/aiconfigurator/.git/lfs/incomplete -type f -delete || exit 1; \
      fi; \
      timeout 300s git -C /opt/src/aiconfigurator lfs pull --include='src/aiconfigurator/systems/data/h100_sxm/**' \
        && break; \
      test "${attempt}" -lt 3 || exit 1; \
    done \
    && git -C /opt/src/aiconfigurator rev-parse HEAD | grep -Fx "${AICONFIGURATOR_COMMIT}" \
    && aic_data_dir=/opt/src/aiconfigurator/src/aiconfigurator/systems/data/h100_sxm \
    && test -d "${aic_data_dir}" \
    && ! grep -RIl --include='*.txt' '^version https://git-lfs.github.com/spec/v1$' \
        "${aic_data_dir}" \
    && python -m pip install /opt/src/aiconfigurator \
    && python -m pip install --no-deps /opt/src/hisim

RUN useradd --create-home --uid 10001 --shell /bin/bash app \
    && mkdir -p /workspace /home/app/.cache \
    && chown -R app:app /workspace /home/app/.cache

COPY docker/entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chmod 0755 /usr/local/bin/entrypoint.sh

USER app
WORKDIR /workspace
ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
CMD ["server"]
