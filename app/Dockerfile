FROM grafana/k6:latest AS k6-bin

FROM python:3.11-slim

COPY --from=k6-bin /usr/bin/k6 /usr/bin/k6

WORKDIR /app
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

COPY . .

EXPOSE 8000
CMD ["uvicorn", "main:app", "--host", "0.0.0.0", "--port", "8000"]
