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

WORKDIR /opt/src/sglang
RUN cp python/pyproject_cpu.toml python/pyproject.toml \
    && python -m pip install --constraint /tmp/requirements.cpu.txt ./python \
    && cp sgl-kernel/pyproject_cpu.toml sgl-kernel/pyproject.toml \
    && python -m pip install --no-build-isolation ./sgl-kernel

COPY third_party/tair-kvcache/hisim /opt/src/hisim

RUN python -m pip install --constraint /tmp/requirements.cpu.txt numpy scikit-learn xgboost

RUN python -m pip install \
        "aiconfigurator @ git+https://github.com/ai-dynamo/aiconfigurator.git@${AICONFIGURATOR_COMMIT}" \
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
