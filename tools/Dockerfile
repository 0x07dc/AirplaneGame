FROM python:3.12-alpine
WORKDIR /app
COPY master_server.py .
EXPOSE 8080
HEALTHCHECK --interval=30s --timeout=3s --retries=3 \
  CMD python3 -c "import urllib.request; urllib.request.urlopen('http://localhost:8080/health')" || exit 1
ENTRYPOINT ["python3", "master_server.py", "--host", "0.0.0.0", "--port", "8080"]
