FROM python:3.11-slim

# ffmpeg for audio conversion
RUN apt-get update && apt-get install -y --no-install-recommends \
    ffmpeg \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /app

COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

COPY app/ ./app/
COPY templates/ ./templates/

ENV PYTHONUNBUFFERED=1
ENV FLASK_APP=app/main.py

EXPOSE 5000

CMD ["python", "-u", "app/main.py"]
