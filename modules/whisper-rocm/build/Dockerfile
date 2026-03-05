FROM rocm/pytorch:rocm7.2_ubuntu24.04_py3.12_pytorch_release_2.7.1

ENV PYTHONUNBUFFERED=1
ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update && apt-get install -y --no-install-recommends \
    ffmpeg libsndfile1 \
    && rm -rf /var/lib/apt/lists/*

RUN pip install --no-cache-dir \
    transformers accelerate \
    fastapi uvicorn python-multipart \
    soundfile

WORKDIR /app
COPY server.py .
RUN chown -R ubuntu:ubuntu /app

RUN mkdir -p /home/ubuntu/.cache/huggingface && chown -R ubuntu:ubuntu /home/ubuntu/.cache

USER ubuntu

EXPOSE 8000

CMD ["bash", "-c", "[ -z \"$HSA_OVERRIDE_GFX_VERSION\" ] && unset HSA_OVERRIDE_GFX_VERSION; exec python server.py"]
