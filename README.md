# Whisper Transkriptionsdienst

Selbst gehosteter Audio-Transkriptionsdienst für Baustellenbegehungen. Sprache rein, deutscher Text raus — mit Fachvokabular für Elektroinstallation und Holzständerbau.

Basiert auf [faster-whisper](https://github.com/guillaumekleindienst/faster-whisper) (large-v3), läuft auf CPU oder NVIDIA-GPU, geschützt über Authelia OIDC.

---

## Features

- **Drag & Drop Upload** — m4a, mp3, wav, ogg, flac, webm; mehrere Dateien gleichzeitig
- **Warteschlange mit Live-Fortschritt** — pro Datei, Echtzeit-Polling
- **Modellauswahl in der UI** — large-v3, medium, small, base
- **Editierbarer Initial-Prompt** — vorbelegt mit Fachvokabular für Zahlen und Fachbegriffe
- **Segmente mit Zeitstempeln** — aufklappbar, direkt in der UI
- **Export** — TXT, SRT, JSON; Transkripte serverseitig in einem Volume gespeichert
- **REST-API** — für automatisierte Aufrufe und die iOS-App
- **OIDC-Auth via Authelia** — Bearer Token (iOS) + Cookie-Session (Browser)

---

## Schnellstart

```bash
git clone https://github.com/mbay-ODW/whisper-service.git
cd whisper-service
cp .env.example .env
# .env anpassen (siehe ENV-Variablen unten)
docker compose up -d --build
```

Beim ersten Start lädt Docker das Whisper-Modell (~3 GB für large-v3). Fortschritt im Log:

```bash
docker logs -f whisper-service
# → Model large-v3 loaded successfully.
```

---

## ENV-Variablen

| Variable | Default | Beschreibung |
|---|---|---|
| `WHISPER_MODEL` | `large-v3` | Modell: `large-v3`, `medium`, `small`, `base` |
| `AUTH_TOKEN` | *(leer)* | Bearer-Token für Direktzugriff ohne Traefik (Entwicklung) |
| `TRUST_PROXY_AUTH` | `true` | Authelia `Remote-User`-Header vertrauen |
| `OIDC_ISSUER` | *(leer)* | Authelia-URL, z. B. `https://auth.example.com` |
| `OIDC_CLIENT_ID` | `whisper-ios` | Client-ID für die iOS-App |
| `WHISPER_HOST` | `whisper.example.com` | Hostname für Traefik-Routing |

---

## Traefik + Authelia

Der Dienst läuft hinter Traefik und wird durch Authelia geschützt. Der Container selbst braucht keine eigene Auth-Logik — Authelia setzt den `Remote-User`-Header, dem Flask vertraut.

### 1. Traefik-Labels (bereits in docker-compose.yml)

```yaml
labels:
  - "traefik.enable=true"
  - "traefik.http.routers.whisper.rule=Host(`whisper.example.com`)"
  - "traefik.http.routers.whisper.entrypoints=websecure"
  - "traefik.http.routers.whisper.tls=true"
  - "traefik.http.routers.whisper.middlewares=authelia@docker"
  - "traefik.http.services.whisper.loadbalancer.server.port=5000"
```

Sicherstellen dass der Container im selben `traefik`-Netzwerk läuft:

```yaml
networks:
  traefik:
    external: true
```

### 2. Authelia OIDC-Client (für iOS-App)

In `authelia-oidc-client.yml` liegt der fertige Snippet. In die Authelia-Konfiguration einfügen:

```yaml
identity_providers:
  oidc:
    clients:
      - client_id: 'whisper-ios'
        client_name: 'Whisper Memo iOS'
        public: true                          # kein Client-Secret nötig
        authorization_policy: 'one_factor'
        redirect_uris:
          - 'whispermemo://oauth/callback'    # Custom URL Scheme der iOS-App
        scopes: [openid, profile, email]
        grant_types: [authorization_code]
        pkce_challenge_method: 'S256'
        token_endpoint_auth_method: 'none'
        access_token_lifespan: '1h'
        refresh_token_lifespan: '90d'
```

### 3. Auth-Flow

```
Browser:  Traefik → Authelia (Cookie-Session) → Remote-User Header → Flask ✓
iOS-App:  Authelia OIDC (PKCE) → Access Token → Bearer → Traefik → Authelia validiert → Flask ✓
```

---

## API

### GET /api/config
Öffentlich — liefert OIDC-Konfiguration für die iOS-App.
```bash
curl https://whisper.example.com/api/config
# → {"oidc_issuer": "...", "oidc_client_id": "whisper-ios", "model_default": "large-v3", ...}
```

### POST /api/transcribe
Datei hochladen, Job-ID zurückbekommen:
```bash
curl -X POST https://whisper.example.com/api/transcribe \
  -H "Authorization: Bearer <token>" \
  -F "file=@aufnahme.m4a" \
  -F "model=large-v3" \
  -F "initial_prompt=Elektroinstallation Holzständerbau: NYM 3x1,5 mm²"
# → {"job_id": "abc-123", "status": "queued"}
```

### GET /api/jobs/`<id>`
Status und Ergebnis abfragen:
```bash
curl https://whisper.example.com/api/jobs/abc-123 \
  -H "Authorization: Bearer <token>"
# → {"status": "done", "full_text": "...", "segments": [...], "duration": 142.3}
```

### Warten bis fertig (Shell)
```bash
TOKEN="..."
JOB_ID="abc-123"
while true; do
  RESP=$(curl -s https://whisper.example.com/api/jobs/$JOB_ID \
    -H "Authorization: Bearer $TOKEN")
  STATUS=$(echo $RESP | python3 -c "import sys,json; print(json.load(sys.stdin)['status'])")
  echo "Status: $STATUS"
  [ "$STATUS" = "done" ] && echo $RESP | python3 -c "import sys,json; print(json.load(sys.stdin)['full_text'])" && break
  [ "$STATUS" = "error" ] && echo "Fehler!" && break
  sleep 3
done
```

### GET /api/jobs
Alle Jobs auflisten:
```bash
curl https://whisper.example.com/api/jobs \
  -H "Authorization: Bearer <token>"
```

### POST /api/jobs/`<id>`/cancel
Job abbrechen (Warteschlange oder laufend).

### DELETE /api/jobs/`<id>`/delete
Job aus der Liste entfernen.

### GET /api/download/`<id>`/`<format>`
Ergebnis herunterladen. Format: `txt`, `srt`, `json`.
```bash
curl https://whisper.example.com/api/download/abc-123/srt \
  -H "Authorization: Bearer <token>" -o transkript.srt
```

---

## GPU (NVIDIA)

Den `deploy`-Block in `docker-compose.yml` auskommentieren:

```yaml
deploy:
  resources:
    reservations:
      devices:
        - driver: nvidia
          count: 1
          capabilities: [gpu]
```

Mit GPU läuft large-v3 auf einer RTX 3080 in ~30 Sekunden für 8 Minuten Audio. Ohne GPU (CPU + int8) dauert es je nach Hardware 3–10×länger.

---

## Volumes

| Volume | Pfad im Container | Inhalt |
|---|---|---|
| `whisper_models` | `/model_cache` | Modell-Dateien (large-v3 ≈ 3 GB) |
| `whisper_transcripts` | `/transcripts` | Transkripte als `.txt` (Datum + Dateiname) |

---

## Nginx Reverse Proxy (alternativ zu Traefik)

```nginx
location / {
    proxy_pass http://localhost:5050/;
    proxy_set_header Host $host;
    proxy_set_header X-Real-IP $remote_addr;
    client_max_body_size 500m;
    proxy_read_timeout 600s;
    proxy_send_timeout 600s;
}
```

HTTPS terminiert am Proxy — der Container läuft nur HTTP intern.

---

## Verwandte Projekte

- **[whisper-memo-ios](https://github.com/mbay-ODW/whisper-memo-ios)** — Native iOS-App für Baustellenbegehungen (Aufnahme → Upload → Transkript)
