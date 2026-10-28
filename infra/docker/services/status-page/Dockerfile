FROM mirror.gcr.io/library/python:3.12-alpine
ENV PYTHONDONTWRITEBYTECODE=1 PYTHONUNBUFFERED=1
WORKDIR /app
RUN mkdir -p /data && chown 65532:65532 /data
COPY availability.py server.py page.py ./
USER 65532:65532
EXPOSE 8080
HEALTHCHECK --interval=30s --timeout=5s --start-period=30s --retries=3 \
  CMD python -c "import os, ssl; from urllib.request import urlopen; urlopen('https://localhost:8080/status.json', context=ssl.create_default_context(cafile=os.environ['STATUS_TLS_CA']), timeout=3)"
CMD ["python", "server.py"]
