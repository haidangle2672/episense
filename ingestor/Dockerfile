FROM python:3.12-slim-bookworm
ENV PYTHONUNBUFFERED=1
WORKDIR /app
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt
COPY app.py .
# Chạy bằng user thường, không dùng root
RUN useradd -r -u 10001 appuser
USER appuser
CMD ["python", "app.py"]