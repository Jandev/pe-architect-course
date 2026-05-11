FROM python:3.11-slim

# Build-time arguments bake the version and colour into the image
# so each tag genuinely differs: v1=blue, v2=green
ARG APP_VERSION=v1
ARG APP_COLOR=blue

WORKDIR /app

# Create non-root user for security (with explicit UID/GID)
RUN groupadd -r appuser -g 1001 && \
    useradd -u 1001 -r -g appuser -m -d /app -s /sbin/nologin -c "App user" appuser

# Copy requirements first to leverage Docker cache
COPY requirements.txt .

# Install dependencies
RUN pip install --no-cache-dir -r requirements.txt

# Copy application code
COPY main.py .

# Change ownership to non-root user
RUN chown -R appuser:appuser /app

# Switch to non-root user
USER 1001

# Bake version/colour into the image so v1 and v2 are distinguishable
# even without explicit env vars at runtime
ENV VERSION=${APP_VERSION} \
    COLOR=${APP_COLOR}

# Expose port
EXPOSE 8000

# Health check
HEALTHCHECK --interval=30s --timeout=30s --start-period=5s --retries=3 \
    CMD curl -f http://localhost:8000/health || exit 1

CMD ["uvicorn", "main:app", "--host", "0.0.0.0", "--port", "8000"]
