FROM python:3.11-slim

ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    PORT=8000

WORKDIR /app

COPY kagenti/tools/github-elicitation-tool/pyproject.toml ./pyproject.toml
RUN pip install --no-cache-dir --upgrade pip && \
    pip install --no-cache-dir fastapi>=0.115.0 httpx>=0.27.0 "uvicorn[standard]>=0.34.0"

COPY kagenti/tools/github-elicitation-tool/app.py ./app.py

EXPOSE 8000

CMD ["uvicorn", "app:app", "--host", "0.0.0.0", "--port", "8000"]