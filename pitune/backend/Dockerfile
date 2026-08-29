FROM python:3.12-slim

# ffmpeg: needed by yt-dlp's FFmpegExtractAudio postprocessor, used only by the
# /api/save endpoint to re-encode a saved track to MP3. The streaming endpoint
# (/api/stream) does not need it — that path pipes the original audio-only
# container straight through with no re-encode.
# curl: used by the compose healthcheck.
RUN apt-get update \
    && apt-get install -y --no-install-recommends ffmpeg curl \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /app

COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

COPY app ./app

EXPOSE 8000
CMD ["uvicorn", "app.main:app", "--host", "0.0.0.0", "--port", "8000"]
