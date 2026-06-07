# Whisper Transkriptionsdienst

Selbst gehostete Sprachtranskription mit faster-whisper, optimiert für deutsche Baustellenmemos.

## Schnellstart

```bash
cp .env.example .env
# AUTH_TOKEN und ggf. WHISPER_MODEL anpassen
docker compose up -d --build
```

Oberfläche: http://localhost:5050?token=<AUTH_TOKEN>

## ENV-Variablen

| Variable | Default | Beschreibung |
|---|---|---|
| `WHISPER_MODEL` | `large-v3` | Modell: `large-v3`, `medium`, `small`, `base` |
| `AUTH_TOKEN` | `changeme` | Bearer-Token für UI und API |

## GPU (NVIDIA)

Im `docker-compose.yml` den `deploy`-Block auskommentieren:

```yaml
deploy:
  resources:
    reservations:
      devices:
        - driver: nvidia
          count: 1
          capabilities: [gpu]
```

Ohne GPU läuft der Dienst mit CPU + `int8` – langsamer, aber funktionsfähig.

## API

### POST /api/transcribe
Datei hochladen, Job-ID zurückbekommen:
```bash
curl -X POST http://localhost:5050/api/transcribe \
  -H "Authorization: Bearer changeme" \
  -F "file=@aufnahme.m4a" \
  -F "model=large-v3"
# → {"job_id": "...", "status": "queued"}
```

### GET /api/jobs/<id>
Status und Ergebnis abfragen:
```bash
curl http://localhost:5050/api/jobs/<job_id> \
  -H "Authorization: Bearer changeme"
```

### Warten bis fertig (Shell-Loop)
```bash
JOB_ID="..."
while true; do
  STATUS=$(curl -s http://localhost:5050/api/jobs/$JOB_ID \
    -H "Authorization: Bearer changeme" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d['status'])")
  echo "Status: $STATUS"
  [ "$STATUS" = "done" ] && break
  [ "$STATUS" = "error" ] && break
  sleep 5
done
```

## Reverse Proxy (nginx)

```nginx
location /whisper/ {
    proxy_pass http://localhost:5050/;
    proxy_set_header Host $host;
    proxy_set_header X-Real-IP $remote_addr;
    client_max_body_size 500m;
    proxy_read_timeout 600s;
}
```

HTTPS terminiert am Proxy – der Container selbst läuft nur HTTP.

## Volumes

| Volume | Inhalt |
|---|---|
| `whisper_models` | Modell-Cache (large-v3 ≈ 3 GB) |
| `whisper_transcripts` | Gespeicherte Transkripte als .txt |
