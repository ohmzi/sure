# CUDA base: the host has an NVIDIA runtime (verified in the step-0 probe). The
# CPU alternative is the same image with `paddlepaddle` instead of
# `paddlepaddle-gpu` and a plain python base — chosen deliberately if the probe
# failed, never by accident.
#
# Ubuntu 22.04 (Python 3.10), not 24.04 (3.12): paddlex 3.0.0 pins
# `pandas<=1.5.3`, which has no cp312 wheel and cannot be built on 3.12, so
# PaddleOCR 3.0.0 is unusable on 3.12. 22.04 also matches its `numpy==1.24.4`
# pin for `python_version < "3.12"`.
FROM nvidia/cuda:12.6.3-cudnn-runtime-ubuntu22.04

# poppler-utils is pdf2image's backend; without it every PDF 422s with an
# ENOENT that looks like a corrupt document. libgomp1 is the OpenMP runtime the
# GPU `paddle` wheel links (libgomp.so.1); the CUDA runtime base does not carry
# it, and without it even `import paddle` fails.
RUN apt-get update && apt-get install -y --no-install-recommends \
      python3 python3-pip poppler-utils libgl1 libglib2.0-0 libgomp1 \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /srv

# 22.04 ships pip 22.0.2, which predates `--break-system-packages`; upgrade so
# the install below is well-defined.
RUN python3 -m pip install --upgrade pip

COPY requirements.txt .
# Cache mount: pip's HTTP cache survives a failed build, so a resolution retry
# does not re-download the ~2 GB of paddlepaddle-gpu + CUDA wheels. The cache is
# a BuildKit mount and is not copied into the image.
RUN --mount=type=cache,target=/root/.cache/pip \
    pip3 install --break-system-packages -r requirements.txt

# Bake the weights in at build time: a container that downloads models on first
# request fails the first document and looks like an outage.
#
# The GPU `paddle` wheel links libcuda.so.1, which only exists inside a container
# started by the NVIDIA runtime — never during `docker build`, so a bare import
# dies with "libcuda.so.1: cannot open shared object file". This image ships the
# CUDA forward-compatibility stub for exactly that case at /usr/local/cuda/compat;
# it is put on LD_LIBRARY_PATH *for this step only* so the import resolves and the
# models download. The final image's environment is left untouched, so at runtime
# the toolkit-injected driver libcuda.so.1 is what paddle loads.
#
# The kwargs mirror app.py's engine() exactly — notably use_textline_orientation,
# which pulls the line-orientation model. If they drift, that model would only be
# fetched on the first real request.
RUN LD_LIBRARY_PATH=/usr/local/cuda/compat:$LD_LIBRARY_PATH \
    python3 -c "from paddleocr import PaddleOCR; PaddleOCR(use_textline_orientation=True, lang='en')"

COPY app.py .

EXPOSE 9000
CMD ["python3", "-m", "uvicorn", "app:app", "--host", "0.0.0.0", "--port", "9000", "--workers", "1"]
