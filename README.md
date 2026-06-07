# Whisper Service

> Selbst gehostete Sprache-zu-Text-Pipeline für die Baustelle — Server, Web-UI und native iOS-App in einem Repo.

Nimm Memos auf der Baustelle auf, lass sie automatisch per [faster-whisper](https://github.com/SYSTRAN/faster-whisper) transkribieren, durchsuche und teile die Ergebnisse. Datenhoheit bleibt zu Hause — auf deinem Server.

---

## Was drin ist

| Teil | Stack | Pfad |
|---|---|---|
| **Server** | Python · Flask · faster-whisper · Docker · GHCR | [`server/`](./server) |
| **iOS-App** | SwiftUI · iOS 17+ · xcodegen | [`ios/`](./ios) |
| **CI** | GitHub Actions baut Image bei jedem Push auf `main` | [`.github/workflows/build.yml`](./.github/workflows/build.yml) |
| **Deploy-Compose** | Stack zieht das fertige Image | [`docker-compose.yml`](./docker-compose.yml) |

---

## Features

### Server / Web-UI

- 🎙 **Multi-Format-Upload** — m4a, mp3, wav, ogg, flac, webm, mp4
- ⚡ **GPU oder CPU** — faster-whisper erkennt CUDA automatisch, fällt sonst auf int8-CPU zurück
- 📋 **Modell-Verwaltung im UI** — `large-v3`, `medium`, `small`, `base` plus beliebige HuggingFace-CT2-Modelle
- 🗂 **Jobs nach Datum gruppiert** — Heute / Gestern / Datum
- 🔁 **Retry & Cancel** für fehlgeschlagene Jobs
- 🔐 **Hybrid-Auth** — Browser via [Authelia](https://www.authelia.com/) Forward-Auth, iOS/API via statischem App-Token
- 🔑 **Token-Management im UI** — Tokens erstellen/widerrufen per Klick
- 📤 **Native Share-API** — Transkript per WhatsApp/Mail/Messages teilen
- 💾 **Persistente Volumes** — Modelle und Transkripte überleben Container-Restarts

### iOS-App (WhisperMemo)

- 🎤 **One-Tap-Aufnahme** mit Waveform-Visualisierung
- 🎧 **AirPods / Bluetooth-Headset** als Mikrofon (HFP)
- 📶 **Offline-Queue** — Aufnahmen werden lokal gespeichert und automatisch hochgeladen, sobald der Server erreichbar ist
- 🩺 **Echte Reachability** — Server-`/health` wird alle 30 s geprobet (nicht nur NWPathMonitor)
- 📊 **Statistik & Speicher** — lokaler Footprint, Queue-Größe, verwaiste Aufnahmen aufräumen
- 🗣 **Initial Prompt** für Fachvokabular (Elektroinstallation, Holzständerbau, etc.)
- 📤 **Teilen** über das native Share-Sheet (Swipe oder Toolbar)

---

## Architektur

```
                       ┌────────────────────────┐
   Browser ─ Authelia ─┤ whisper-ui  (Traefik) │ ── Cookie-Session
   (forward-auth)      │                       │
                       │ whisper-api (Traefik) │ ── Bearer-Token
   iOS-App ────────────┤  (kein Authelia)      │
   (Bearer)            │                       │
   Public ─────────────┤ whisper-public        │ ── /health, /api/config
                       └──────────┬─────────────┘
                                  │
                         ┌────────▼────────┐
                         │  Flask-Service  │
                         │  faster-whisper │
                         │     ffmpeg      │
                         └────┬───────┬────┘
                              │       │
                      /model_cache  /transcripts
                      (Docker Volumes)
```

**Drei Traefik-Router teilen sich denselben Host** (`whisper.example.com`):

| Router | Pfad | Middleware | Zweck |
|---|---|---|---|
| `whisper-public` | `/health`, `/api/config` | — | Reachability-Probes, App-Setup |
| `whisper-api` | `PathPrefix(/api)` | — | Flask validiert Bearer-Token selbst |
| `whisper-ui` | alles andere | `authelia` Forward-Auth | Browser-Session via Cookie |

Beim ersten Aufruf von `GET /` setzt Flask anhand des `Remote-User`-Headers eine signierte Session-Cookie. AJAX-Requests an `/api/*` (kein Authelia auf der Route!) authentifizieren sich dann via Cookie. iOS-Clients senden stattdessen `Authorization: Bearer <token>`.

---

## Quickstart

### Voraussetzungen

- Docker-Host mit Traefik + Authelia (z.B. via [Portainer](https://www.portainer.io/) auf TrueNAS)
- Externes Docker-Network `traefik`
- (Optional) NVIDIA-GPU + nvidia-docker für schnelles `large-v3`

### Stack starten

```yaml
# docker-compose.yml — Image kommt direkt von ghcr.io
services:
  whisper:
    image: ghcr.io/mbay-odw/whisper-service:latest
    container_name: whisper-service
    restart: unless-stopped
    environment:
      - WHISPER_MODEL=large-v3
      - TRUST_PROXY_AUTH=true
      - FLASK_SECRET_KEY=<generiere-32-bytes-hex>
    volumes:
      - whisper_models:/model_cache
      - whisper_transcripts:/transcripts
    networks:
      - traefik

networks:
  traefik:
    external: true

volumes:
  whisper_models:
  whisper_transcripts:
```

Traefik-Labels werden über einen File-Provider gesetzt (siehe [Traefik-Konfiguration](#traefik-konfiguration) unten).

```bash
docker compose up -d
docker logs -f whisper-service          # warten bis "Model large-v3 loaded successfully."
```

### Web-UI öffnen

`https://whisper.example.com` → Authelia-Login → Tab **App-Tokens** → Token für die iOS-App erstellen.

### iOS-App installieren

```bash
cd ios
brew install xcodegen        # nur einmal
xcodegen generate
open WhisperMemo.xcodeproj   # in Xcode → Build & Run aufs Gerät
```

Beim ersten Start: Server-URL eintragen + den eben erstellten App-Token einfügen.

---

## Konfiguration

### Server-Env-Vars

| Variable | Default | Bedeutung |
|---|---|---|
| `WHISPER_MODEL` | `large-v3` | Default-Modell; pro Job überschreibbar |
| `TRUST_PROXY_AUTH` | `true` | `Remote-User`/`X-Forwarded-User` als Auth akzeptieren |
| `FLASK_SECRET_KEY` | random | Persistente Session-Cookies über Restarts hinweg |

### Persistente Dateien

```
/transcripts/
├── .tokens.json        ← Bearer-Tokens (vom UI verwaltet)
├── .models.json        ← Custom-HuggingFace-Modelle
└── *.txt               ← gespeicherte Transkripte (Dateiname = Timestamp)
/model_cache/
└── …                   ← faster-whisper download_root (gigabyte-große Modelle)
```

### Traefik-Konfiguration

Beispiel-File-Provider (`dynamic.yml`):

```yaml
http:
  routers:
    whisper-public:
      rule: "Host(`whisper.example.com`) && (Path(`/health`) || Path(`/api/config`))"
      service: whisper
      entryPoints: [websecure]
      tls: {}
      priority: 30
    whisper-api:
      rule: "Host(`whisper.example.com`) && PathPrefix(`/api`)"
      service: whisper
      entryPoints: [websecure]
      tls: {}
      priority: 20
    whisper-ui:
      rule: "Host(`whisper.example.com`)"
      service: whisper
      entryPoints: [websecure]
      tls: {}
      priority: 10
      middlewares: [authelia@docker]
  services:
    whisper:
      loadBalancer:
        servers:
          - url: "http://whisper-service:5000"
```

---

## API-Referenz

Alle Bearer-geschützten Endpunkte erwarten `Authorization: Bearer <token>`.

| Method | Pfad | Zweck |
|---|---|---|
| `GET` | `/health` | Liveness + Modell-Status (public) |
| `GET` | `/api/config` | Default-Modell + Liste verfügbarer Modelle (public) |
| `GET` | `/api/model-status` | Modell-Loading-Status |
| `POST` | `/api/upload` | Multi-File-Upload (form-data) |
| `POST` | `/api/transcribe` | Single-File-Upload, gibt `job_id` zurück |
| `GET` | `/api/jobs` | Job-Liste (Summary) |
| `GET` | `/api/jobs/<id>` | Job-Detail inkl. Transkript |
| `POST` | `/api/jobs/<id>/cancel` | Laufenden Job abbrechen |
| `POST` | `/api/jobs/<id>/retry` | Fehlerhaften Job neu starten |
| `DELETE` | `/api/jobs/<id>/delete` | Job löschen |
| `GET` | `/api/download/<id>/<fmt>` | `txt` · `srt` · `json` |
| `GET` | `/api/models` | Built-in + Custom-Modelle |
| `POST` | `/api/models/add` | Custom-Modell hinzufügen (Browser-Session) |
| `POST` | `/api/models/<name>/delete` | Custom-Modell entfernen (Browser-Session) |
| `GET` | `/tokens` | Token-Liste (Browser-Session) |
| `POST` | `/tokens/create` | Token erstellen (Browser-Session) |
| `POST` | `/tokens/<value>/delete` | Token widerrufen (Browser-Session) |

> Token-Endpunkte liegen unter `/tokens/`, _nicht_ `/api/tokens/` — sie müssen durch den `whisper-ui` Router (mit Authelia) gehen, damit `Remote-User` gesetzt wird.

### Beispiel: Job per cURL

```bash
TOKEN="dein-app-token"
curl -X POST https://whisper.example.com/api/transcribe \
  -H "Authorization: Bearer $TOKEN" \
  -F file=@aufnahme.m4a \
  -F model=large-v3 \
  -F initial_prompt="Elektroinstallation Holzständerbau …"
# → {"job_id":"...","status":"queued"}
```

---

## Development

### Server lokal starten

```bash
cd server
python -m venv .venv && source .venv/bin/activate
pip install -r requirements.txt
TRUST_PROXY_AUTH=false python -m app.main
# → http://localhost:5000
```

`TRUST_PROXY_AUTH=false` deaktiviert die Authelia-Prüfung; du brauchst dann einen Bearer-Token in `/transcripts/.tokens.json`:

```bash
mkdir -p /tmp/transcripts && echo '{"dev-token": "Lokal"}' > /tmp/transcripts/.tokens.json
```

### Image manuell bauen

```bash
docker build -t whisper-service:dev server/
```

### CI-Pipeline

Push auf `main` mit Änderungen unter `server/` triggert [`.github/workflows/build.yml`](./.github/workflows/build.yml). Image landet als `ghcr.io/mbay-odw/whisper-service:latest` und `:<sha>`.

Stack-Redeploy auf TrueNAS via Portainer-API:

```bash
TOKEN="ptr_…"
curl -X PUT -H "X-API-Key: $TOKEN" -H "Content-Type: application/json" \
  -d @stack-payload.json \
  "https://portainer.example.com/api/stacks/49?endpointId=1"
```

### iOS-App in Xcode

```bash
cd ios
xcodegen generate          # nach jeder neuen .swift-Datei
open WhisperMemo.xcodeproj
```

Code-Signing-Team in `project.yml` setzen, dann Build & Run.

---

## Roadmap-Ideen

- [ ] WebSocket-Live-Updates statt Polling
- [ ] Multi-User mit Per-User-Token-Scopes
- [ ] Suche über alle Transkripte (Volltext)
- [ ] iOS Share-Extension: aus anderen Apps direkt hochladen
- [ ] Watch-App für One-Tap-Aufnahme vom Handgelenk

---

## Lizenz

MIT — siehe [`LICENSE`](./LICENSE).
