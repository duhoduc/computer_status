FROM python:3.12-slim
WORKDIR /app
COPY app*.py live*.html ./
ENV DB_PATH=/data/status.db PORT=8765
VOLUME /data
EXPOSE 8765
CMD ["sh", "-c", "exec python -u $([ -f app_${MACHINE}.py ] && echo app_${MACHINE}.py || echo app.py)"]
