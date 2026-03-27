# We use a slim Python base to keep the image small.
# "slim" cuts out compilers and build tools — fine because we have no C extensions.
FROM python:3.12-slim

# Set workdir — all subsequent commands run from here inside the container.
WORKDIR /app

# Copy requirements first, THEN code.
# Docker builds in layers. If requirements.txt hasn't changed, Docker reuses
# the cached pip install layer and skips it on the next build.
# This makes iterative development much faster.
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

# Copy application code.
COPY main.py .

# Expose the port the app listens on (documentation only — docker-compose
# actually maps this, but it's good practice to declare it here).
EXPOSE 8000

# Start uvicorn — FastAPI's ASGI server.
# --host 0.0.0.0 means listen on all interfaces (required inside a container).
# --port 8000 is the port we expose.
CMD ["uvicorn", "main:app", "--host", "0.0.0.0", "--port", "8000"]
