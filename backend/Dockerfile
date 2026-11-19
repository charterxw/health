FROM python:3.11-slim@sha256:07d4824036af339fa1b6ef769cc99d9c10a141769538b52b3b597c84f7a7b535
WORKDIR /app
ENV PYTHONDONTWRITEBYTECODE=1 PYTHONUNBUFFERED=1 HOME=/tmp
COPY requirements.txt ./
RUN python -m pip install --no-cache-dir --require-hashes -r requirements.txt \
    && python -m pip uninstall -y pip setuptools wheel \
    && groupadd --gid 10001 health \
    && useradd --uid 10001 --gid 10001 --no-create-home --shell /usr/sbin/nologin health
COPY app/ ./app/
RUN chmod -R a+rX /app/app
USER 10001:10001
EXPOSE 8000
HEALTHCHECK --interval=10s --timeout=5s --start-period=20s --retries=3 \
  CMD python -c "import urllib.request; urllib.request.urlopen('http://127.0.0.1:8000/api/readyz',timeout=3).read()"
CMD ["sh","-c","umask 0077; exec uvicorn app.main:app --host 0.0.0.0 --port 8000 --no-proxy-headers --limit-concurrency 64 --timeout-keep-alive 5"]
