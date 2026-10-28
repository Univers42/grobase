FROM mirror.gcr.io/library/python:3.12-alpine
ENV PYTHONDONTWRITEBYTECODE=1 PYTHONUNBUFFERED=1
WORKDIR /app
RUN mkdir -p /data && chown 65532:65532 /data
COPY availability.py server.py status.html ./
USER 65532:65532
EXPOSE 8080
HEALTHCHECK --interval=30s --timeout=5s --start-period=30s --retries=3 \
  CMD python -c "from urllib.request import urlopen; urlopen('http://localhost:8080/status.json', timeout=3)"
CMD ["python", "server.py"]
