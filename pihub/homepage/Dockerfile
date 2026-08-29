# One container serves both the API and the static frontend — no separate
# nginx needed for this service. Keeps it inside the "idle RAM under 100MB"
# budget: a single lightweight Python process instead of Python + nginx.
FROM python:3.12-slim

WORKDIR /app

COPY backend/requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

COPY backend/ ./backend/
COPY frontend/src ./frontend
# config/ is bind-mounted at runtime (see docker-compose.yml), not baked
# into the image — that's the whole point of it being editable without a
# rebuild.

WORKDIR /app/backend
ENV FRONTEND_DIR=/app/frontend
ENV CONFIG_DIR=/app/config

EXPOSE 8080
CMD ["uvicorn", "main:app", "--host", "0.0.0.0", "--port", "8080"]
