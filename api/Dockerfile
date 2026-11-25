# api/Dockerfile
FROM python:3.12-slim
WORKDIR /app
RUN useradd -r -u 10001 app            # không chạy bằng root
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt
COPY app ./app
USER app
CMD ["uvicorn", "app.main:app", "--host", "0.0.0.0", "--port", "8000"]