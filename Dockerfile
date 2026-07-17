FROM python:3.12-slim

WORKDIR /app

# Install LiteLLM (pinned to a recent stable release)
RUN pip install --no-cache-dir "litellm>=1.50,<2" && \
    rm -rf /root/.cache/pip

COPY docker-entrypoint.sh ./
RUN chmod +x docker-entrypoint.sh

EXPOSE 4000

HEALTHCHECK --interval=30s --timeout=5s --retries=3 \
    CMD curl -f http://localhost:4000/health/liveliness || exit 1

ENTRYPOINT ["./docker-entrypoint.sh"]
